import SwiftUI
import SVGAPlayer_swift

/// 只读 250ms 快照的诊断面板；不直接访问播放器的逐帧对象。
struct DemoDiagnosticsView: View {
    /// 页面或批次持有的同一个播放会话。
    let session: DemoSession

    /// 按证据来源分组，所有文本可复制，导出失败明确显示。
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("诊断快照").font(.title2.bold())
                Spacer()
                Button("导出 JSON") { session.exportManually() }.accessibilityIdentifier("diagnostics.export")
            }
            GroupBox("文件与构建") { identity }
            GroupBox("播放状态") { playback }
            GroupBox("载入与缓存") { loading }
            GroupBox("准备与呈现") { rendering }
            GroupBox("资源") {
                VStack(alignment: .leading) {
                    row("最近帧 CPU 输入", bytes(session.diagnostics?.latestCPUInputBytes))
                    row("GPU 输入留存", bytes(session.diagnostics?.retainedGPUInputBytes))
                    Text("预算计费不是进程 RSS。GPU 完成只证明命令执行；人工画面结果默认 pending。")
                        .foregroundStyle(.secondary)
                }
            }
            DemoDiagnosticConsole(actions: session.actions, frames: session.diagnostics?.events ?? [], content: session.contentEvents)
            if let error = session.errorMessage { Text(error).foregroundStyle(.red) }
            if let error = session.exportError { Text(error).foregroundStyle(.red) }
            if let url = session.reportURL {
                ShareLink("分享报告", item: url)
                Text(url.path).font(.caption2).accessibilityIdentifier("diagnostics.reportPath")
            }
        }
        .font(.caption).monospacedDigit().textSelection(.enabled)
        .accessibilityIdentifier("detail.diagnostics")
    }

    /// 来源和运行身份齐全，未提供的构建标记不伪造。
    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("相对路径", session.resource?.relativePath ?? "未选择")
            row("完整路径", session.resource?.url.path ?? "未选择")
            row("字节数", bytes(session.resource?.byteCount))
            row("SHA-256", session.loadReport?.sha256 ?? "未观测")
            row("runID", session.runID.uuidString)
            row("播放器", session.player.id.uuidString)
            row("安装会话", session.playback?.installationID?.uuidString ?? "未安装")
            row("系统", session.environment.system)
            row("CPU", session.environment.cpu)
            row("构建号 / 配置", "\(session.environment.build) / \(session.environment.configuration)")
            row("构建标记", session.environment.artifactMarker ?? "未提供")
        }
    }

    /// 请求、GPU 完成和完整轮数分别显示，不把首帧渲染当完整播放。
    private var playback: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("状态", session.status)
            row("请求位置", position(session.playback?.requestedPosition))
            row("最近有效 GPU 完成位置", position(session.playback?.gpuCompletedPosition))
            row("时长", session.playback?.duration.map { String(format: "%.3f s", $0) } ?? "未安装")
            row("已完成轮数", String(session.playback?.completedIterations ?? 0))
            row("从头完整轮数", String(session.playback?.completedWholeIterations ?? 0))
            row("循环设置", session.playback.map { String(describing: $0.loop) } ?? "未安装")
            row("内容 / 定位版本", session.playback.map { String($0.revision) } ?? "未安装")
            row("主错误", session.errorMessage ?? session.playback?.failure ?? "无")
        }
    }

    /// 加载阶段 nil 显示未执行，缓存统计为共享 loader 当前累计值。
    private var loading: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let report = session.loadReport {
                row("策略 / 结果 / 路径", "\(report.policy.rawValue) / \(report.status.rawValue) / \(report.cachePath.rawValue)")
                row("读取 / 摘要", "\(milliseconds(report.readSeconds)) / \(milliseconds(report.digestSeconds))")
                row("解析 / 共享等待", "\(milliseconds(report.parseSeconds)) / \(milliseconds(report.sharedWaitSeconds))")
                row("加载总耗时", milliseconds(report.totalSeconds))
                if let error = report.error { row("加载错误", error) }
            } else { Text("尚未执行加载") }
            if let cache = session.cache {
                row("命中 / 未命中 / 共享", "\(cache.hits) / \(cache.misses) / \(cache.shared)")
                row("实际解析 / 在途", "\(cache.parses) / \(cache.inFlight)")
                row("淘汰 / 失效 / 丢弃旧结果", "\(cache.evictions) / \(cache.invalidations) / \(cache.discardedResults)")
                row("失败 / 取消", "\(cache.failures) / \(cache.cancellations)")
                row("留存 / 上限", "\(cache.retainedMovies) 份 · \(bytes(cache.retainedBytes)) / \(bytes(cache.byteLimit))")
            }
            Text("命中仍包含读取和摘要；共享等待与实际解析可能重叠，不能简单相加。")
                .foregroundStyle(.secondary)
        }
    }

    /// 首次提交、GPU 完成与系统呈现保持独立，计数只来自真实回调。
    private var rendering: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let value = session.diagnostics {
                row("影片准备", milliseconds(value.preparationSeconds))
                row("首次提交", milliseconds(value.firstSubmitSeconds))
                row("首次有效 GPU 完成", milliseconds(value.firstGPUCompletionSeconds))
                row("首次有效系统呈现", milliseconds(value.firstPresentationSeconds))
                row("最近 / 最大帧准备", "\(milliseconds(value.latestFramePreparationSeconds)) / \(milliseconds(value.maximumFramePreparationSeconds))")
                row("累计 GPU 时间", milliseconds(value.totalGPUSeconds))
                row("提交 / GPU 完成", "\(value.submittedCommands) / \(value.gpuCompletions)")
                row("系统呈现", value.systemPresentations.map(String.init) ?? "尚未观测")
                row("过期呈现 / 零时间跳过", "\(value.stalePresentations) / \(value.zeroTimeSkips)")
                row("请求合并 / 结果丢弃", "\(value.coalescedRequests) / \(value.discardedResults)")
                row("drawable 不可用", String(value.drawableFailures))
            } else { Text("尚未安装或尚无匹配当前文件的诊断") }
        }
    }

    /// 标签和值可换行，长路径不挤掉其他诊断。
    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 同时显示整数帧与独立进度，避免混用两个定位坐标。
    private func position(_ value: SVGAPosition?) -> String {
        guard let value else { return "未观测" }
        return "frame=\(value.frame) · " + String(format: "progress=%.4f · %.3f s", value.progress, value.seconds)
    }

    /// 未执行的阶段保持 nil 语义，不格式化成零毫秒。
    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.3f ms", $0 * 1000) } ?? "未执行 / 未观测"
    }

    /// 字节同时保留整数和可读单位，计费口径不冒充 RSS。
    private func bytes(_ value: Int?) -> String {
        value.map { "\($0) B (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)))" } ?? "未观测"
    }
}

/// 有界控制台的显示筛选和冻结；原始快照与导出内容始终保留。
private struct DemoDiagnosticConsole: View {
    /// 最多 128 条宿主交互。
    let actions: [DemoAction]
    /// 最多 128 条库帧阶段。
    let frames: [SVGAFrameEvent]
    /// 最多 256 条内容请求。
    let content: [SVGAContentEvent]
    /// 对显示行进行文本过滤，不修改输入。
    @State private var query = ""
    /// 默认隐藏正常逐帧阶段，保留操作与异常。
    @State private var showsFrames = false
    /// 冻结仅影响屏幕文本。
    @State private var frozen = false
    /// 点击冻结时的显示行快照。
    @State private var frozenLines: [String] = []

    /// 固定高度和横向滚动支持完整复制，不向系统控制台逐帧输出。
    var body: some View {
        GroupBox("有界控制台") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("过滤操作、key、阶段或错误", text: $query)
                HStack {
                    Toggle("显示正常帧事件", isOn: $showsFrames)
                    Button(frozen ? "继续更新" : "冻结显示") {
                        if !frozen { frozenLines = lines }
                        frozen.toggle()
                    }
                }
                ScrollView([.horizontal, .vertical]) {
                    Text((frozen ? frozenLines : lines).filter {
                        query.isEmpty || $0.localizedCaseInsensitiveContains(query)
                    }.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }.frame(height: 220)
            }
        }.accessibilityIdentifier("diagnostics.console")
    }

    /// 墙钟操作与单调帧事件分开标注，不拼成虚假的统一时间基准。
    private var lines: [String] {
        actions.map { "[\($0.date.formatted(date: .omitted, time: .standard))] ACTION \($0.operation) key=\($0.key ?? "—") \($0.parameters)" }
        + content.map { "[mono \(String(format: "%.3f", $0.monotonicTime))] CONTENT \($0.operation.rawValue) \($0.status.rawValue) key=\($0.key) \($0.detail ?? "")" }
        + frames.filter { showsFrames || $0.accepted == false || [.drawableUnavailable, .discarded].contains($0.stage) }.map {
            "[mono \(String(format: "%.3f", $0.monotonicTime))] \($0.stage.rawValue) frame=\($0.position?.frame.description ?? "—") request=\($0.requestID?.uuidString ?? "—") accepted=\($0.accepted.map(String.init) ?? "—")"
        }
    }
}
