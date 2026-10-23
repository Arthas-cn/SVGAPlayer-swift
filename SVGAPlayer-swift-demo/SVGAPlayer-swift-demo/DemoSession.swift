import Foundation
import Observation
import SVGAPlayer_swift

/// 一个资源使用一个库播放会话；只组织用户命令和低频诊断，不做合成或缓存。
@MainActor @Observable final class DemoSession {
    /// 永久复用的唯一播放器，切换宿主不替换此实例。
    let player = SVGAPlayer()
    /// 详情独立、批次共用的报告身份。
    let runID: UUID
    /// 真实构建与系统信息，整个会话保持一致。
    let environment = DemoEnvironment.current()
    /// 当前文件，没有加载过时为 nil。
    private(set) var resource: DemoResource?
    /// 真实精灵目录，不提供虚构占位 key。
    private(set) var keys: [String] = []
    /// 文件画布、帧率、总帧数的摘要。
    private(set) var metadata = "尚未加载"
    /// 源影片秒数，未解析前为零，仅用于 UI 和批次预算。
    private(set) var duration = 0.0
    /// 源帧数，未解析前为零。
    private(set) var frameCount = 0
    /// 包含读取、准备和首个有效 GPU 完成的加载状态。
    private(set) var isLoading = false
    /// 是否已安装并观察到首次有效 GPU 完成。
    private(set) var isLoaded = false
    /// 主加载/播放错误，内容替换失败仅进入日志。
    private(set) var errorMessage: String?
    /// 单独的导出失败，不能被播放器状态刷新覆盖。
    private(set) var exportError: String?
    /// 当前加载的一一对应报告。
    private(set) var loadReport: SVGALoadReport?
    /// 每 250ms 更新的控制快照。
    private(set) var playback: SVGAPlaybackSnapshot?
    /// 每 250ms 更新的渲染证据。
    private(set) var diagnostics: SVGAPlaybackDiagnostics?
    /// 共享解析缓存的当前统计。
    private(set) var cache: SVGACacheStatistics?
    /// 最近 128 条宿主操作，过滤只在 UI 进行。
    private(set) var actions: [DemoAction] = []
    /// 最近 256 条库内容事件。
    private(set) var contentEvents: [SVGAContentEvent] = []
    /// 成功写出的报告路径，失败不生成虚假路径。
    private(set) var reportURL: URL?
    /// 当前会话是否仅用于列表预览，预览不导出完整播放验收。
    private let preview: Bool
    /// 详情自动导出；批次由自身统一归档。
    private let autoExport: Bool
    /// 当前安装是否已经自动导出，避免 finished 状态每 250ms 写盘。
    private var exportedCompletion = false
    /// 串行用户命令，新命令撤销并等待前一命令退出。
    @ObservationIgnored private var command: Task<Void, Never>?
    /// 当前加载的结构化桥接任务；重载和清空先取消并排空它，防止旧加载覆盖新意图。
    @ObservationIgnored private var activeLoad: Task<Void, Error>?

    /// 指定报告身份与用途；默认详情只拥有此一个播放会话。
    init(runID: UUID = UUID(), preview: Bool = false, autoExport: Bool = true) {
        self.runID = runID
        self.preview = preview
        self.autoExport = autoExport && !preview
    }

    /// 防御性撤销交互，正常退出使用 shutdown 等资源排空。
    isolated deinit { command?.cancel(); activeLoad?.cancel() }

    /// 页面任务的完整生命周期：自动加载播放、低频观察，取消后等待释放。
    func run(_ resource: DemoResource, loop: SVGALoop = .finite(1)) async {
        async let loading: Void = loadForPage(resource, loop: loop)
        await monitor()
        _ = await loading
        await shutdown()
    }

    /// 错误已在 load 中固化，页面继续显示诊断直到离开。
    private func loadForPage(_ resource: DemoResource, loop: SVGALoop) async {
        do { try await load(resource, loop: loop) }
        catch { /* 不再重复改变已记录的错误或取消状态。 */ }
    }

    /// 从源文件加载并等待首次有效 GPU 完成；读取和准备也包含在 15 秒上限内。
    func load(_ resource: DemoResource, loop: SVGALoop = .finite(1),
              policy: SVGALoadPolicy = .useCache, autoplay: Bool = true) async throws {
        let previous = activeLoad
        previous?.cancel()
        let task = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            try await loadCurrent(resource, loop: loop, policy: policy, autoplay: autoplay)
        }
        activeLoad = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// 只由串行加载任务调用，初始页面加载也参与相同的取消链。
    private func loadCurrent(_ resource: DemoResource, loop: SVGALoop,
                             policy: SVGALoadPolicy, autoplay: Bool) async throws {
        self.resource = resource
        isLoading = true
        isLoaded = false
        errorMessage = nil
        exportError = nil
        loadReport = nil
        diagnostics = nil
        playback = nil
        contentEvents = []
        keys = []
        duration = 0
        frameCount = 0
        metadata = "加载中"
        exportedCompletion = false
        reportURL = nil
        append("load", parameters: "\(resource.id); policy=\(policy.rawValue); loop=\(loop); autoplay=\(autoplay)")
        defer { isLoading = false }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.prepare(resource, policy: policy) }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw DemoError.firstGPUTimeout
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            try Task.checkCancellation()
            try await player.changeLoop(to: loop)
            if autoplay { try await player.play() }
            isLoaded = true
            append(autoplay ? "autoplay" : "prepared")
            await refresh()
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if !cancelled { errorMessage = error.localizedDescription }
            append(cancelled ? "loadCancelled" : "loadFailed", parameters: error.localizedDescription)
            await player.pause()
            await refresh()
            if autoExport && !cancelled { await export(reason: "loadFailed") }
            throw error
        }
    }

    /// 加载报告由返回值或错误直接取得，不从全局最近日志猜测归属。
    private func prepare(_ resource: DemoResource, policy: SVGALoadPolicy) async throws {
        await player.clear()
        let result: SVGALoadResult
        do { result = try await SVGALoader.shared.load(from: resource.url, policy: policy) }
        catch let failure as SVGALoadFailure { loadReport = failure.report; throw failure }
        loadReport = result.report
        let movie = result.movie
        keys = movie.spriteKeys
        duration = movie.duration
        frameCount = movie.frameCount
        metadata = "\(Int(movie.size.width)) × \(Int(movie.size.height)) · "
            + String(format: "%.3f 秒 · %.1f fps · %d 帧", movie.duration, movie.frameRate, movie.frameCount)
        try Task.checkCancellation()
        try await player.install(movie)
        // 列表为所有资源保留会话；LazyVStack 尚未创建宿主不是文件失败，也不能据此抢预览名额。
        if preview { return }
        while await player.snapshot.gpuCompletedPosition == nil {
            try Task.checkCancellation()
            if let error = await player.snapshot.failure { throw DemoError.message(error) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// 只读值快照约每 250ms 刷新，界面不访问逐帧 Metal 对象。
    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            if autoExport, !exportedCompletion, playback?.state == .finished {
                exportedCompletion = true
                await export(reason: "naturalEnd")
            }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
        }
    }

    /// 汇总库快照；显示和导出共用这些值，主错误不被后续 empty 状态覆盖。
    func refresh() async {
        playback = await player.snapshot
        let current = await player.diagnostics
        diagnostics = current?.movieIdentity == loadReport?.sha256 ? current : nil
        contentEvents = await player.contentEvents
        cache = await SVGALoader.shared.statistics
        if let failure = playback?.failure { errorMessage = failure }
        if !isLoading { isLoaded = playback?.movieIdentity != nil && diagnostics?.firstGPUCompletionSeconds != nil && playback?.failure == nil }
    }

    /// 页面退出撤销并等待交互与库资源；不依赖 View 的销毁时机。
    func shutdown() async {
        activeLoad?.cancel()
        command?.cancel()
        _ = await activeLoad?.result
        await command?.value
        command = nil
        activeLoad = nil
        await player.shutdown()
        isLoaded = false
    }

    /// 清空按钮也终止尚未完成的首次加载，避免随后又安装已被用户清掉的影片。
    func clear() async {
        activeLoad?.cancel()
        _ = await activeLoad?.result
        activeLoad = nil
        await player.clear()
        isLoaded = false
    }

    /// 串行执行复现操作，错误仅记录为本次操作失败，不把内容失败升级为主播放失败。
    func perform(_ name: String, key: String? = nil, parameters: String = "",
                 action: @escaping @MainActor (SVGAPlayer) async throws -> Void) {
        append(name, key: key, parameters: parameters)
        let previous = command
        previous?.cancel()
        command = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do { try await action(player) }
            catch is CancellationError { append("operationCancelled", key: key, parameters: name) }
            catch { append("operationFailed", key: key, parameters: "\(name): \(error.localizedDescription)") }
            await refresh()
        }
    }

    /// 逐帧只改变整数帧序号，暂停后才定位，日志不把它写成归一化进度。
    func step(_ delta: Int) {
        perform("stepFrame", parameters: "delta=\(delta)") { [self] player in
            await player.pause()
            let current = await player.snapshot.requestedPosition?.frame ?? 0
            let target = min(max(0, current + delta), max(0, frameCount - 1))
            append("seekFrame", parameters: "frame=\(target)")
            try await player.seek(toFrame: target)
        }
    }

    /// 重载可走缓存、强制解析或只准备，继续复用原播放器。
    func reload(policy: SVGALoadPolicy = .useCache, autoplay: Bool = true) {
        guard let resource else { return }
        perform("reload", parameters: "policy=\(policy.rawValue); autoplay=\(autoplay)") { [self] player in
            let loop = await player.snapshot.loop
            try await load(resource, loop: loop, policy: policy, autoplay: autoplay)
        }
    }

    /// 追加有界宿主日志，不在逐帧绘制回调中调用。
    func append(_ operation: String, key: String? = nil, parameters: String = "") {
        actions.append(DemoAction(operation, key: key, parameters: parameters))
        if actions.count > 128 { actions.removeFirst(actions.count - 128) }
    }

    /// 生成独立阶段报告；预览、seek 跳过的轮次和手动暂停都不能冒充完整播放。
    func report(reason: String, error: String? = nil) async -> DemoResourceReport? {
        await refresh()
        guard let resource else { return nil }
        let finished = playback?.state == .finished && (playback?.completedWholeIterations ?? 0) > 0
        return DemoResourceReport(runID: runID, resource: resource, environment: environment, endReason: reason,
            parsing: loadReport?.status.rawValue ?? "notExecuted",
            rendering: (diagnostics?.gpuCompletions ?? 0) > 0 ? "completed" : "notCompleted",
            playback: preview ? "preview" : (finished ? "finished" : playback?.state == .finished ? "endedAfterSeeking" : playback?.state.rawValue ?? "notExecuted"),
            visual: "pending", load: loadReport, snapshot: playback, diagnostics: diagnostics, cache: cache,
            actions: actions, contentEvents: contentEvents, error: error ?? errorMessage)
    }

    /// 用户点击时异步导出，真实成功后才显示路径并可分享。
    func exportManually() {
        perform("exportJSON") { [self] _ in await export(reason: "manualExport") }
    }

    /// 单份完成和手动导出共用的持久化路径，失败显示独立错误。
    func export(reason: String) async {
        guard let report = await report(reason: reason) else { return }
        do {
            reportURL = try await DemoReportStore.save(report, runID: runID, name: "detail-" + player.id.uuidString)
            exportError = nil
        } catch {
            exportError = "报告导出失败：\(error.localizedDescription)"
            append("exportFailed", parameters: error.localizedDescription)
        }
    }

    /// 用户可读的状态，不用“加载中”掩盖超时。
    var status: String {
        if let errorMessage { return "失败：\(errorMessage)" }
        if isLoading { return "加载与首帧准备中" }
        return playback?.state.rawValue ?? "未加载"
    }
}
