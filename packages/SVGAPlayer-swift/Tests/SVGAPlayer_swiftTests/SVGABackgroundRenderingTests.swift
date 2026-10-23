import Foundation
import Metal
import QuartzCore
import Testing
@testable import SVGAPlayer_swift

/// 后台 Metal 许可切换回归；不以权限拒绝伪造 GPU 完成，也不能把其他驱动错误一并吞掉。
struct SVGABackgroundRenderingTests {
    /// 截图中的 Metal Code=7 可恢复，其他错误域的相同数字、内存错误和 nil 不被误分类。
    @Test func onlyMetalPermissionErrorsAreRecoverable() {
        #expect(GPUCompletion.isPermissionError(NSError(domain: MTLCommandBufferErrorDomain, code: 7)))
        #expect(!GPUCompletion.isPermissionError(NSError(domain: "OtherDomain", code: 7)))
        #expect(!GPUCompletion.isPermissionError(NSError(domain: MTLCommandBufferErrorDomain,
            code: Int(MTLCommandBufferError.Code.outOfMemory.rawValue))))
        #expect(!GPUCompletion.isPermissionError(nil))
    }

    /// 一次在途权限拒绝不改变播放设置或位置证据，后续有效 GPU 完成仍能正常接收。
    @Test func permissionDenialKeepsSessionRecoverable() async throws {
        let player = SVGAPlayer()
        let movie = try await fixture()
        try await player.install(movie)
        try await player.changeLoop(to: .infinite)
        try await player.play()
        let request = await player.backgroundTestRequest()
        let denied = NSError(domain: MTLCommandBufferErrorDomain, code: 7)
        await player.completed(request, result: completion(error: denied))
        #expect(await player.snapshot.state == .playing)
        #expect(await player.snapshot.failure == nil)
        #expect(await player.snapshot.loop == .infinite)
        #expect(await player.snapshot.gpuCompletedPosition == nil)
        #expect(await player.diagnostics?.gpuCompletions == 0)
        #expect(await player.diagnostics?.gpuUnavailableSkips == 1)
        #expect(await player.diagnostics?.events.last?.stage == .gpuUnavailable)
        await player.completed(request, result: completion(error: nil))
        #expect(await player.snapshot.gpuCompletedPosition == request.position)
        #expect(await player.diagnostics?.gpuCompletions == 1)
        await player.shutdown()
    }

    /// 真实 GPU 资源错误仍终止播放并保留主错误，修复不能退化为忽略所有 Metal 失败。
    @Test func otherGPUFailuresRemainFatal() async throws {
        let player = SVGAPlayer()
        try await player.install(fixture())
        try await player.play()
        let request = await player.backgroundTestRequest()
        let error = NSError(domain: MTLCommandBufferErrorDomain,
                            code: Int(MTLCommandBufferError.Code.outOfMemory.rawValue))
        await player.completed(request, result: completion(error: error))
        #expect(await player.snapshot.state == .failed)
        #expect(await player.snapshot.failure != nil)
        #expect(await player.diagnostics?.gpuUnavailableSkips == 0)
        await player.shutdown()
    }

    /// 取得目标后才停用时也不能 present 或 commit；恢复后相同未提交命令可以真实完成。
    @Test func inactiveGatePreventsSubmission() async throws {
        let gate = MetalSubmissionGate()
        let context = try MetalContext.shared.get()
        let command = try #require(context.queue.makeCommandBuffer())
        gate.setEnabled(false)
        var presented = false
        let submitted = gate.submit(command) { presented = true }
        #expect(!submitted)
        #expect(!presented)
        #expect(command.status == .notEnqueued)
        gate.setEnabled(true)
        let completed = await withCheckedContinuation { continuation in
            command.addCompletedHandler { continuation.resume(returning: $0.status == .completed) }
            let accepted = gate.submit(command) {}
            #expect(accepted)
        }
        #expect(completed)
    }

    /// 停用只等待已提交工作被调度；新命令仍被关闭的门拒绝，不要求 CPU 读回或等待整帧显示。
    @Test func deactivationDrainsScheduledWork() async throws {
        let gate = MetalSubmissionGate()
        let context = try MetalContext.shared.get()
        let command = try #require(context.queue.makeCommandBuffer())
        let accepted = gate.submit(command) {}
        #expect(accepted)
        gate.setEnabled(false)
        #expect(command.status == .scheduled || command.status == .completed)
        let next = try #require(context.queue.makeCommandBuffer())
        let rejected = gate.submit(next) {}
        #expect(!rejected)
        #expect(next.status == .notEnqueued)
    }

    /// 恢复前台要主动重绘暂停画面；不能只依赖正在播放的下一次时钟 tick。
    @Test @MainActor func reactivationRequestsPausedFrame() async throws {
        let player = SVGAPlayer()
        try await player.install(fixture())
        let binding = SurfaceBinding(player: player, layer: CAMetalLayer()) { false }
        let deadline = ContinuousClock.now + .seconds(2)
        while await player.surfaceID != binding.id {
            guard ContinuousClock.now < deadline else { throw SVGAError.invalidOperation("宿主绑定超时") }
            try await Task.sleep(for: .milliseconds(1))
        }
        binding.setRenderingEnabled(false)
        #expect(!binding.surface.submissionGate.isEnabled)
        let revision = await player.snapshot.revision
        binding.setRenderingEnabled(true)
        while await player.snapshot.revision == revision {
            guard ContinuousClock.now < deadline else { throw SVGAError.invalidOperation("恢复重绘超时") }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(binding.surface.submissionGate.isEnabled)
        #expect(await player.snapshot.state == .paused)
        await player.shutdown()
    }

    /// 使用包内真实影片，错误直接交回测试，不构造合法 SVGA 二进制。
    private func fixture() async throws -> SVGAMovie {
        let url = try #require(Bundle.module.url(forResource: "1", withExtension: "svga", subdirectory: "Fixtures"))
        return try await SVGALoader().load(from: url).movie
    }

    /// 模拟异步驱动交回的纯值，错误分类和生产回调完全使用同一入口。
    private func completion(error: NSError?) -> GPUCompletion {
        GPUCompletion(succeeded: error == nil, error: error?.description, seconds: nil,
                      observed: Monotonic.now, isUnavailable: GPUCompletion.isPermissionError(error))
    }
}

/// 测试只捕获当前帧身份，不改变生产播放器 API。
private extension SVGAPlayer {
    /// 在同一 actor 隔离内取得安装、版本与请求位置，供异步回调回归使用。
    func backgroundTestRequest() -> FrameRequest {
        FrameRequest(id: UUID(), installationID: installationID, revision: revision, sequence: sequence,
                     position: timeline?.snapshot(), clear: false)
    }
}
