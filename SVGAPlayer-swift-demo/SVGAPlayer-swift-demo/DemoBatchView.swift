import Foundation
import Observation
import SwiftUI
import SVGAPlayer_swift

/// 一轮目录批播拥有者，整个批次只复用一个库播放器。
@MainActor @Observable final class DemoBatchModel {
    /// 整批共用身份，单份报告也使用它。
    let runID: UUID
    /// 唯一播放器和低频诊断会话。
    let session: DemoSession
    /// 全部计划项，尚未尝试的项也保留。
    private(set) var planned: [DemoResource] = []
    /// 只记录实际开始的尝试。
    private(set) var results: [DemoResourceReport] = []
    /// 当前正在尝试的文件身份，结束后为 nil。
    private(set) var currentID: String?
    /// 包括取消收尾与报告导出的运行状态。
    private(set) var isRunning = false
    /// 用户取消或页面退出的终结标记。
    private(set) var cancelled = false
    /// 批报告已实际写入的 URL。
    private(set) var reportURL: URL?
    /// 真实导出失败或批次级错误。
    private(set) var error: String?
    /// 一次页面生命周期只自动开始一次。
    private var started = false
    /// 可由按钮或页面取消的批次工作。
    @ObservationIgnored private var work: Task<Void, Never>?

    /// 创建整批唯一会话，单份自然结束时由批次统一写报告。
    init() {
        let id = UUID()
        runID = id
        session = DemoSession(runID: id, autoExport: false)
    }

    /// 页面正常退出等待 run 收尾；销毁防御性取消未结束工作。
    isolated deinit { work?.cancel() }

    /// 固化本轮完整目录，不从搜索结果派生；任务取消后也等待报告和资源释放。
    func run(_ resources: [DemoResource]) async {
        guard !started else { return }
        started = true
        planned = resources
        isRunning = true
        let task = Task { await execute() }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        work = nil
        isRunning = false
    }

    /// 取消停在当前份，不把未开始的计划项写成失败或成功。
    func cancel() {
        session.append("cancelBatch", parameters: "current=\(currentID ?? "none")")
        work?.cancel()
    }

    /// 顺序执行并在每份完成时固化独立结果，失败继续，取消停止。
    private func execute() async {
        for resource in planned {
            if Task.isCancelled { cancelled = true; break }
            currentID = resource.id
            let startedAt = ProcessInfo.processInfo.systemUptime
            var reason = "naturalEnd"
            var failure: String?
            do {
                try await session.load(resource, loop: .finite(1))
                let deadline = startedAt + max(20, session.duration * 2 + 10)
                while true {
                    try Task.checkCancellation()
                    let snapshot = await session.player.snapshot
                    if let error = snapshot.failure { throw DemoError.message(error) }
                    if snapshot.state == .finished { break }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw DemoError.playbackTimeout }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    cancelled = true
                    reason = "cancelled"
                } else {
                    reason = "failed"
                    failure = error.localizedDescription
                }
                await session.player.pause()
            }
            if let report = await session.report(reason: reason, error: failure) {
                results.append(report)
                do { _ = try await DemoReportStore.save(report, runID: runID, name: resource.id) }
                catch { self.error = "单份报告写入失败：\(error.localizedDescription)" }
            }
            if cancelled { break }
        }
        currentID = nil
        await session.shutdown()
        await export()
    }

    /// 完整一轮必须由报告的自然完成证据确认。
    var completedCount: Int { results.filter { $0.playback == "finished" && $0.endReason == "naturalEnd" }.count }
    /// 取消不计失败，未运行项也不计失败。
    var failedCount: Int { results.filter { $0.endReason == "failed" }.count }

    /// 手动或结束时导出整个计划与已尝试结果；失败明确显示。
    func export() async {
        let report = DemoBatchReport(runID: runID, planned: planned, attempted: results, cancelled: cancelled,
                                     completedMovies: completedCount, failedMovies: failedCount)
        do { reportURL = try await DemoReportStore.save(report, runID: runID, name: "batch") }
        catch { self.error = "批报告导出失败：\(error.localizedDescription)" }
    }
}

/// 顺序批播验收页，画布与诊断始终绑定同一个播放器。
struct DemoBatchView: View {
    /// 导航时传入的完整目录，与列表搜索无关。
    let resources: [DemoResource]
    /// 整批拥有者与唯一会话。
    @State private var batch = DemoBatchModel()

    /// 未运行、进行中与已尝试结果全部保留在计划清单中。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(batch.cancelled ? "批播已取消" : batch.isRunning ? "顺序播放中" : "批播结束")
                    .font(.title2.bold())
                Text("计划 \(resources.count) · 已尝试 \(batch.results.count) · 完整一轮 \(batch.completedCount) · 失败 \(batch.failedCount)")
                HStack {
                    Button("取消") { batch.cancel() }.disabled(!batch.isRunning)
                    Button("导出整批报告") { Task { await batch.export() } }
                    if let url = batch.reportURL { ShareLink("分享整批报告", item: url) }
                }.buttonStyle(.bordered)
                SVGAView(player: batch.session.player)
                    .frame(height: 260).frame(maxWidth: .infinity)
                    .background(.gray.opacity(0.15)).accessibilityIdentifier("batch.canvas")
                Text(batch.currentID ?? "没有正在播放的文件").font(.headline)
                if let error = batch.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let url = batch.reportURL { Text(url.path).font(.caption).textSelection(.enabled) }
                DemoDiagnosticsView(session: batch.session)
                GroupBox("完整计划") {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(resources) { resource in
                            VStack(alignment: .leading) {
                                Text(resource.id).bold()
                                if let result = batch.results.first(where: { $0.resource.id == resource.id }) {
                                    Text("解析 \(result.parsing) · 渲染 \(result.rendering) · 播放 \(result.playback) · 画面 \(result.visual)")
                                    if let error = result.error { Text(error).foregroundStyle(.red) }
                                } else { Text(batch.currentID == resource.id ? "正在尝试" : "尚未运行").foregroundStyle(.secondary) }
                            }.font(.caption).textSelection(.enabled)
                            .accessibilityIdentifier("batch.item.\(resource.id)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding()
        }
        .navigationTitle("播放全部")
        .accessibilityIdentifier("batch.diagnostics")
        .task { await batch.run(resources) }
        .task { await batch.session.monitor() }
    }
}
