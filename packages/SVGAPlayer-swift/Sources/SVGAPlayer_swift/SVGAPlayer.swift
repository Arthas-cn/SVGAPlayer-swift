import Foundation

/// 独立于显示宿主的播放会话 actor；管理时间轴、内容版本和 GPU 提交，不承担读文件职责。
public actor SVGAPlayer {
    /// 播放器持久身份，创建宿主或切换宿主不会变化。
    public nonisolated let id = UUID()
    /// 已准备的源影片与只读 GPU 输入，未安装时为 nil。
    var scene: MetalMovie?
    /// 音频拥有者，全部后续操作在本 actor 串行执行。
    var audio: AudioPlayback?
    /// 当前显示边界；宿主保持薄层，实际编码仍在本 actor。
    var surface: MetalSurface?
    /// 当前显示边界身份，防止旧宿主的迟到 detach 解绑新宿主。
    var surfaceID: UUID?
    /// 当前安装身份，清空后为 nil。
    var installationID: UUID?
    /// 最近一次安装/清空意图，跨 await 后必须匹配。
    var installationIntent = UUID()
    /// 定位、内容或安装改变的代数，GPU 回调据此拒绝旧结果。
    var revision: UInt64 = 0
    /// 与源文件关联的纯值时间轴。
    var timeline: PlaybackTimeline?
    /// 当前播放控制状态，不代表系统已经呈现。
    var state: SVGAPlaybackState = .empty
    /// 有限或无限循环，默认完整播放一轮。
    var loop: SVGALoop = .finite(1)
    /// 自然结束后默认保留最后帧。
    var endBehavior: SVGAEndBehavior = .holdLastFrame
    /// 默认完整显示源画布。
    var displayMode: SVGADisplayMode = .aspectFit
    /// 主播放错误，不接收单项内容替换失败。
    var failure: String?
    /// 当前安装的最近有效 GPU 完成位置。
    var gpuPosition: SVGAPosition?
    /// 当前安装诊断；清空后保留最后证据，下一次安装重新计数。
    var currentDiagnostics: SVGAPlaybackDiagnostics?
    /// 本安装准备开始的单调时间。
    var installationStarted = Monotonic.now
    /// 后台准备任务；新安装/清空会取消并等待其结束。
    var preparationTask: Task<PreparedInstallation, Error>?
    /// 独立时间轴时钟，宿主不是唯一的播放控制入口。
    var clockTask: Task<Void, Never>?
    /// 最近一次推进时间轴的单调时刻。
    var lastTick = Monotonic.now
    /// 当前安装独占的渲染附件缓存。
    var renderer: MetalRenderer?
    /// 最新尚未提交的帧请求，新的请求合并替代旧请求。
    var pendingFrame: FrameRequest?
    /// 串行提交/等待 GPU 的拥有任务，保证至多一个帧命令在途。
    var renderingTask: Task<Void, Never>?
    /// 单调递增提交序号，用于避免回调倒序覆盖有效完成位置。
    var sequence: UInt64 = 0
    /// 最近有效 GPU 完成序号。
    var completedSequence: UInt64 = 0
    /// 最近有效系统呈现序号。
    var presentedSequence: UInt64 = 0
    /// 自然结束策略要求透明显示时为 true；保留源资源以供重播。
    var clearsDisplay = false
    /// 每个真实 key 当前的图片/文本/隐藏覆盖。
    var content: [String: MetalContent] = [:]
    /// 当前每个 key 的替换意图，决定迟到准备结果能否安装。
    var contentVersions: [String: UUID] = [:]
    /// 正在准备的动态内容，清空必须取消并等待。
    var contentTasks: [UUID: Task<PreparedContent, Error>] = [:]
    /// 最后 256 条内容事件，单条只保留标量与身份。
    var recordedContentEvents: [SVGAContentEvent] = []

    /// 创建空播放会话；资源直到 install 时才分配，可用于无显示宿主的播放控制。
    public init() {}

    /// 防御性撤销拥有的任务；页面正常退出仍应调用 shutdown 等待 GPU 与准备结束。
    deinit {
        clockTask?.cancel()
        preparationTask?.cancel()
        renderingTask?.cancel()
        for task in contentTasks.values { task.cancel() }
    }

    /// 低频读取完整控制快照，未完成的 GPU 或呈现不冒充请求位置。
    public var snapshot: SVGAPlaybackSnapshot {
        SVGAPlaybackSnapshot(playerID: id, installationID: installationID, movieIdentity: scene?.movie.identity,
            state: state, requestedPosition: timeline?.snapshot(), gpuCompletedPosition: gpuPosition,
            duration: scene?.movie.duration, completedIterations: timeline?.completedIterations ?? 0,
            completedWholeIterations: timeline?.completedWholeIterations ?? 0, loop: loop,
            endBehavior: endBehavior, displayMode: displayMode, revision: revision, failure: failure)
    }

    /// 最近安装的可编码渲染证据，没有安装过影片时为 nil。
    public var diagnostics: SVGAPlaybackDiagnostics? { currentDiagnostics }
    /// 有界内容事件快照；失败不会自动升级为主播放失败。
    public var contentEvents: [SVGAContentEvent] { recordedContentEvents }

    /// 安装共享影片并准备第一帧但不自动播放；nil 清空，取消后不安装迟到结果。
    public func install(_ movie: SVGAMovie?) async throws {
        let intent = UUID()
        installationIntent = intent
        revision &+= 1
        clockTask?.cancel()
        clockTask = nil
        audio?.stop()
        let oldPreparation = preparationTask
        oldPreparation?.cancel()
        let oldContent = contentTasks.values.map { $0 }
        for task in oldContent { task.cancel() }
        contentVersions.removeAll()
        let oldRendering = renderingTask
        pendingFrame = nil
        scene = nil
        audio = nil
        timeline = nil
        gpuPosition = nil
        installationID = nil
        content.removeAll()
        failure = nil
        state = movie == nil ? .empty : .preparing
        clearsDisplay = movie == nil
        // 排空旧工作后才释放独占附件；await 期间另一次安装可以进入，必须重新检查意图。
        _ = await oldPreparation?.result
        for task in oldContent { _ = await task.result }
        await oldRendering?.value
        guard installationIntent == intent else { throw CancellationError() }
        renderer = nil
        preparationTask = nil
        guard let movie else {
            requestFrame()
            await renderingTask?.value
            return
        }
        // 已取消的调用可能在准备任务创建前进入；仍需结束 preparing，不能留下没有工作的加载状态。
        if Task.isCancelled {
            state = .empty
            clearsDisplay = true
            requestFrame()
            throw CancellationError()
        }
        let installation = UUID()
        installationID = installation
        installationStarted = Monotonic.now
        currentDiagnostics = SVGAPlaybackDiagnostics(playerID: id, installationID: installation, movieIdentity: movie.identity)
        recordedContentEvents.removeAll()
        let task = Task.detached(priority: .userInitiated) {
            let context = try MetalContext.shared.get()
            async let scene = MetalMovie.prepare(movie, context: context)
            async let audio = AudioPlayback.prepare(movie)
            return try await PreparedInstallation(scene: scene, audio: audio, context: context)
        }
        preparationTask = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard installationIntent == intent else {
                record(.discarded, request: nil, accepted: false)
                throw CancellationError()
            }
            scene = result.scene
            audio = result.audio
            renderer = MetalRenderer(context: result.context)
            timeline = PlaybackTimeline(frameCount: movie.frameCount, frameRate: movie.frameRate,
                                        playbackFrameCount: movie.playbackFrameCount)
            state = .paused
            clearsDisplay = false
            preparationTask = nil
            currentDiagnostics?.preparationSeconds = Monotonic.now - installationStarted
            currentDiagnostics?.retainedGPUInputBytes = result.scene.accountedBytes
            record(.prepared, request: nil, duration: currentDiagnostics?.preparationSeconds)
            requestFrame()
        } catch {
            // 旧安装的取消或错误不能覆盖新安装状态。
            if installationIntent == intent {
                preparationTask = nil
                if error is CancellationError {
                    state = .empty
                    installationID = nil
                } else {
                    failure = String(describing: error)
                    state = .failed
                }
                clearsDisplay = true
                requestFrame()
            }
            throw error
        }
    }

    /// 播放或从暂停处继续；自然结束后的再次播放从头开始计轮。
    public func play() throws {
        guard scene != nil, failure == nil else { throw SVGAError.invalidOperation("尚未准备影片") }
        if state == .playing { return }
        if state == .finished { timeline?.rewind(); revision &+= 1 }
        clearsDisplay = false
        state = .playing
        lastTick = Monotonic.now
        audio?.synchronize(frame: timeline?.frame ?? 0, playing: true)
        requestFrame()
        startClock()
    }

    /// 暂停时间轴和音频；最后的 GPU 命令仍允许完成，不伪造新的显示位置。
    public func pause() {
        if state == .playing { advanceClock() }
        clockTask?.cancel()
        clockTask = nil
        if state == .playing { state = .paused }
        audio?.synchronize(frame: timeline?.frame ?? 0, playing: false)
    }

    /// 回到第一帧并暂停，同时清零轮数；只在准备完成后有效。
    public func rewind() throws {
        guard scene != nil else { throw SVGAError.invalidOperation("尚未准备影片") }
        pause()
        timeline?.rewind()
        state = .paused
        clearsDisplay = false
        revision &+= 1
        requestFrame()
    }

    /// 按整数源帧定位；越界抛错，和 0...1 进度 API 明确分开。
    public func seek(toFrame frame: Int) throws {
        guard let movie = scene?.movie, (0..<movie.frameCount).contains(frame) else {
            throw SVGAError.invalidOperation("帧序号越界或未安装")
        }
        timeline?.seek(frame: frame)
        if state == .finished { state = .paused }
        clearsDisplay = false
        revision &+= 1
        lastTick = Monotonic.now
        audio?.synchronize(frame: frame, playing: state == .playing)
        requestFrame()
    }

    /// 按有限的 0...1 进度定位。1 对应最后一个仍播放的帧；被跳过的尾部空帧只能用整数帧 API 定位。
    public func seek(toProgress progress: Double) throws {
        guard let movie = scene?.movie, progress.isFinite, (0...1).contains(progress) else {
            throw SVGAError.invalidOperation("进度须在 0...1 且已安装影片")
        }
        let lastFrame = (timeline?.playbackFrameCount ?? movie.playbackFrameCount) - 1
        try seek(toFrame: Int((progress * Double(max(0, lastFrame))).rounded()))
    }

    /// 重绘当前帧而不推进时间轴，适用于暂停状态和宿主尺寸变化。
    public func redraw() { requestFrame() }

    /// 更新循环设置；有限次数必须为正，已完成轮数不会因此重置。
    public func changeLoop(to loop: SVGALoop) throws {
        if case .finite(let count) = loop, count <= 0 { throw SVGAError.invalidOperation("有限轮数必须大于零") }
        self.loop = loop
    }

    /// 更新播放结束后的画面策略，不改变当前显示适配。
    public func changeEndBehavior(to behavior: SVGAEndBehavior) { endBehavior = behavior }

    /// 改变画布适配并重绘当前帧，不创建新的播放器或安装会话。
    public func changeDisplayMode(to mode: SVGADisplayMode) {
        displayMode = mode
        revision &+= 1
        requestFrame()
    }

    /// 清空并取消所有未完成替换；等待旧准备和 GPU 释放输入后返回。
    public func clear() async {
        do { try await install(nil) }
        catch { /* nil 安装只有被更新意图取代时才取消；较新的调用负责最终状态。 */ }
    }

    /// 页面退出的完整释放边界；等待资源排空，再解绑当前宿主。
    public func shutdown() async {
        await clear()
        surface = nil
        surfaceID = nil
        renderer = nil
    }

    /// 启动独立于 UI 的单调时间轴；实际帧变化才提交，迟到 tick 按经过时间合并。
    func startClock() {
        clockTask?.cancel()
        // 每个源帧最多唤醒一次；时间轴按实测时间推进，调度延迟不会累积成慢播。
        let interval = 1 / (scene?.movie.frameRate ?? 30)
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                await self?.tick()
            }
        }
    }

    /// 时钟入口，暂停或结束后不再推进。
    func tick() {
        guard state == .playing else { return }
        advanceClock()
    }

    /// 推进源帧并对齐音频；完成轮次的证据来自时间轴，和 GPU 首帧完全独立。
    func advanceClock() {
        let now = Monotonic.now
        let before = timeline?.frame
        let finished = timeline?.advance(seconds: now - lastTick, loop: loop) ?? false
        lastTick = now
        if finished {
            state = .finished
            clockTask?.cancel()
            clockTask = nil
            switch endBehavior {
            case .holdLastFrame: break
            case .returnToFirstFrame: timeline?.position = 0
            case .clear: clearsDisplay = true
            }
        }
        audio?.synchronize(frame: timeline?.frame ?? 0, playing: state == .playing)
        if before != timeline?.frame || finished { requestFrame() }
    }
}

/// 准备任务完成后一次交接的资源集合，未完成时不发布部分场景。
struct PreparedInstallation: Sendable {
    /// 不可变 GPU 输入。
    let scene: MetalMovie
    /// 只由安装目标 actor 后续使用的音频集合。
    let audio: AudioPlayback
    /// 共享只读 Metal 状态。
    let context: MetalContext
}

/// 帧请求身份与安装代；不持有源图像或 GPU 对象。
struct FrameRequest: Sendable {
    /// 单个请求唯一身份。
    let id: UUID
    /// 所属安装，nil 表示清屏。
    let installationID: UUID?
    /// 接收时的内容/定位代数。
    let revision: UInt64
    /// 单调请求序号。
    let sequence: UInt64
    /// 接收时的源位置，清屏为 nil。
    let position: SVGAPosition?
    /// 此请求应显示透明内容而非影片时为 true。
    let clear: Bool
}
