import Foundation
import Metal

/// 播放会话的帧调度与阶段观测；不把系统呈现回调等同于 GPU 完成。
extension SVGAPlayer {
    /// 新宿主替换旧绑定，播放会话和时间轴保持不变。
    func attach(_ surface: MetalSurface, id: UUID) {
        self.surface = surface
        surfaceID = id
        revision &+= 1
        requestFrame()
    }

    /// 只有仍拥有绑定的宿主可以解绑，避免 SwiftUI 切换宿主时旧拆卸覆盖新挂载。
    func detach(id: UUID) {
        guard surfaceID == id else { return }
        surface = nil
        surfaceID = nil
        revision &+= 1
    }

    /// 尺寸、挂载或可见性改变后重绘；旧宿主的迟到布局通知无效。
    func surfaceChanged(id: UUID) {
        guard surfaceID == id else { return }
        revision &+= 1
        requestFrame()
    }

    /// 只保留最新尚未提交的位置，热路径事件进入有界缓冲，不输出到控制台。
    func requestFrame() {
        sequence &+= 1
        let request = FrameRequest(id: UUID(), installationID: installationID, revision: revision,
            sequence: sequence, position: timeline?.snapshot(), clear: clearsDisplay || scene == nil)
        if let previous = pendingFrame {
            currentDiagnostics?.coalescedRequests += 1
            record(.coalesced, request: previous, accepted: false)
        }
        pendingFrame = request
        guard renderingTask == nil else { return }
        renderingTask = Task { [weak self] in await self?.drainFrames() }
    }

    /// 至多一个命令缓冲在途，完成后再处理最新请求；这也界定了 shutdown 的资源释放边界。
    func drainFrames() async {
        while let request = pendingFrame {
            pendingFrame = nil
            await render(request)
        }
        renderingTask = nil
    }

    /// 获取 drawable 后重新检查代数，编码并真实提交；取消/更新不能安装迟到的宿主结果。
    func render(_ request: FrameRequest) async {
        guard let surface else {
            currentDiagnostics?.drawableFailures += 1
            record(.drawableUnavailable, request: request, accepted: false)
            return
        }
        do {
            let context = try MetalContext.shared.get()
            guard let frame = await surface.acquire(context: context) else {
                currentDiagnostics?.drawableFailures += 1
                record(.drawableUnavailable, request: request, accepted: false)
                return
            }
            // 获取 drawable 是 MainActor 暂停点；新 seek、替换、安装或宿主切换都可在此发生。
            guard matches(request), pendingFrame == nil else {
                discard(request)
                return
            }
            let started = Monotonic.now
            if renderer == nil { renderer = MetalRenderer(context: context) }
            guard let renderer else { return }
            let submission = try renderer.encode(scene: request.clear ? nil : scene,
                frame: request.position?.frame ?? 0, target: frame.drawable.texture,
                mode: displayMode, scale: frame.scale, content: content)
            let preparation = Monotonic.now - started
            if request.installationID == currentDiagnostics?.installationID {
                // optional 链的写访问在右值求值前开始；先读取旧值，避免同一结构体的独占访问冲突。
                let maximum = max(currentDiagnostics?.maximumFramePreparationSeconds ?? 0, preparation)
                currentDiagnostics?.latestFramePreparationSeconds = preparation
                currentDiagnostics?.maximumFramePreparationSeconds = maximum
                currentDiagnostics?.latestCPUInputBytes = submission.cpuInputBytes
                currentDiagnostics?.retainedGPUInputBytes = (scene?.accountedBytes ?? 0) + content.values.reduce(0) {
                    $0 + ($1.texture.map { $0.width * $0.height * 4 } ?? 0)
                }
                record(.prepared, request: request, duration: preparation, accepted: true)
            }
            // iOS Simulator SDK 的 MTLDrawable 未提供呈现回调，计数保持 nil，绝不拿 GPU 完成冒充。
            #if !targetEnvironment(simulator)
            frame.drawable.addPresentedHandler { [weak self] drawable in
                let time = drawable.presentedTime
                let observed = Monotonic.now
                Task { await self?.presented(request, time: time, observed: observed) }
            }
            #endif
            let result: GPUCompletion = await withCheckedContinuation { continuation in
                submission.commandBuffer.addCompletedHandler { command in
                    let duration = command.gpuEndTime > command.gpuStartTime && command.gpuStartTime > 0
                        ? command.gpuEndTime - command.gpuStartTime : nil
                    continuation.resume(returning: GPUCompletion(succeeded: command.status == .completed,
                        error: command.error.map { String(describing: $0) }, seconds: duration, observed: Monotonic.now))
                }
                submission.commandBuffer.present(frame.drawable)
                submission.commandBuffer.commit()
                if request.installationID == currentDiagnostics?.installationID {
                    currentDiagnostics?.submittedCommands += 1
                    if currentDiagnostics?.firstSubmitSeconds == nil {
                        currentDiagnostics?.firstSubmitSeconds = Monotonic.now - installationStarted
                    }
                    record(.submitted, request: request, accepted: true)
                }
            }
            completed(request, result: result)
        } catch {
            guard matches(request) else { discard(request); return }
            failure = String(describing: error)
            state = .failed
            clockTask?.cancel()
            clockTask = nil
            audio?.stop()
        }
    }

    /// 记录成功 GPU 完成并仅接受仍有效、未倒序的源位置；清屏不计为影片渲染成功。
    func completed(_ request: FrameRequest, result: GPUCompletion) {
        guard request.installationID == currentDiagnostics?.installationID, request.installationID != nil else { return }
        guard result.succeeded else {
            if matches(request) {
                failure = result.error ?? "Metal 命令未成功完成"
                state = .failed
                clockTask?.cancel()
                clockTask = nil
                audio?.stop()
            }
            return
        }
        if !request.clear { currentDiagnostics?.gpuCompletions += 1 }
        if let seconds = result.seconds {
            let total = (currentDiagnostics?.totalGPUSeconds ?? 0) + seconds
            currentDiagnostics?.totalGPUSeconds = total
        }
        let accepted = matches(request) && request.sequence >= completedSequence && !request.clear
        record(.gpuCompleted, request: request, duration: result.seconds, accepted: accepted, time: result.observed)
        if accepted {
            completedSequence = request.sequence
            gpuPosition = request.position
            if currentDiagnostics?.firstGPUCompletionSeconds == nil {
                currentDiagnostics?.firstGPUCompletionSeconds = result.observed - installationStarted
            }
        } else if !request.clear { discard(request) }
    }

    /// 系统实际显示证据来自 presentedTime；零时间和过时代分别计数。
    func presented(_ request: FrameRequest, time: Double, observed: Double) {
        guard request.installationID == currentDiagnostics?.installationID, request.installationID != nil else { return }
        guard time.isFinite, time > 0 else {
            currentDiagnostics?.zeroTimeSkips += 1
            record(.presentationSkipped, request: request, accepted: false, time: observed)
            return
        }
        let presentations = (currentDiagnostics?.systemPresentations ?? 0) + 1
        currentDiagnostics?.systemPresentations = presentations
        let accepted = matches(request) && request.sequence >= presentedSequence && !request.clear
        if accepted {
            presentedSequence = request.sequence
            if currentDiagnostics?.firstPresentationSeconds == nil {
                currentDiagnostics?.firstPresentationSeconds = observed - installationStarted
            }
        } else { currentDiagnostics?.stalePresentations += 1 }
        record(.presented, request: request, accepted: accepted, time: observed)
    }

    /// 定位/内容更新和安装更新都使旧结果失效；普通播放推进不改变 revision。
    func matches(_ request: FrameRequest) -> Bool {
        request.installationID == installationID && request.revision == revision
    }

    /// 统一记录被更新意图取代的结果，便于诊断丢弃与请求合并的差别。
    func discard(_ request: FrameRequest) {
        currentDiagnostics?.discardedResults += 1
        record(.discarded, request: request, accepted: false)
    }

    /// 追加纯标量有界事件；时间可由系统回调捕获，避免 actor 排队改变观测时刻。
    func record(_ stage: SVGAFrameStage, request: FrameRequest?, duration: Double? = nil,
                accepted: Bool? = nil, time: Double = Monotonic.now) {
        currentDiagnostics?.append(SVGAFrameEvent(stage: stage, monotonicTime: time, requestID: request?.id,
            position: request?.position, durationSeconds: duration, accepted: accepted))
    }
}

/// 命令回调交还的纯值，不把 Metal 命令对象跨 actor 暴露给诊断消费者。
struct GPUCompletion: Sendable {
    /// 命令缓冲是否成功结束。
    let succeeded: Bool
    /// 驱动错误描述，成功时为 nil。
    let error: String?
    /// GPU 实测耗时；驱动没有有效时间时为 nil。
    let seconds: Double?
    /// 回调到达时的单调时间。
    let observed: Double
}
