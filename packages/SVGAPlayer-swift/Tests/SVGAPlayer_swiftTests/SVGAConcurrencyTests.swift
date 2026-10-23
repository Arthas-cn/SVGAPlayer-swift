import Foundation
import Testing
@testable import SVGAPlayer_swift

/// 用真实影片与受控暂停点覆盖共享解析、取消和迟到完成，避免依赖机器速度制造竞争。
struct SVGAConcurrencyTests {
    /// 一个等待者取消只结束自己的报告，另一个等待者仍收到同一次真实解析的影片。
    @Test func cancellingOneSharedWaiterKeepsTheOther() async throws {
        let gate = DecodeGate()
        let loader = SVGALoader(byteLimit: 128 * 1024 * 1024) { data, identity in
            await gate.suspend()
            try Task.checkCancellation()
            return try SVGADecoder.decode(data, identity: identity)
        }
        let url = try fixture()
        let first = Task { try await loader.load(from: url) }
        try await wait { await gate.count == 1 }
        let second = Task { try await loader.load(from: url) }
        try await wait { await loader.statistics.shared == 1 }
        first.cancel()
        do { _ = try await first.value; Issue.record("被取消的等待者不应成功") }
        catch let failure as SVGALoadFailure {
            #expect(failure.report.status == .cancelled)
            #expect(failure.report.parseSeconds == nil)
        }
        await gate.releaseAll()
        let result = try await second.value
        #expect(result.report.cachePath == .joined)
        #expect(result.report.sharedWaitSeconds != nil)
        #expect(result.report.parseSeconds == nil)
        #expect(await loader.statistics.parses == 1)
        #expect(await loader.statistics.retainedMovies == 1)
        #expect(await loader.statistics.inFlight == 0)
    }

    /// 清缓存使旧解析失效但不伤害原调用者，迟到成功不能重新填入缓存。
    @Test func invalidationDiscardsLateCacheWrite() async throws {
        let gate = DecodeGate()
        let loader = SVGALoader(byteLimit: 128 * 1024 * 1024) { data, identity in
            await gate.suspend()
            return try SVGADecoder.decode(data, identity: identity)
        }
        let url = try fixture()
        let loading = Task { try await loader.load(from: url) }
        try await wait { await gate.count == 1 }
        await loader.clearCache()
        await gate.releaseAll()
        #expect(try await loading.value.movie.frameCount == 80)
        let statistics = await loader.statistics
        #expect(statistics.discardedResults == 1)
        #expect(statistics.retainedMovies == 0)
        #expect(statistics.inFlight == 0)
    }

    /// 最后一人取消撤销共享入口，新请求必须建立新解析；旧完成不会覆盖新缓存。
    @Test func lastCancellationStartsANewGeneration() async throws {
        let gate = DecodeGate()
        let loader = SVGALoader(byteLimit: 128 * 1024 * 1024) { data, identity in
            await gate.suspend()
            try Task.checkCancellation()
            return try SVGADecoder.decode(data, identity: identity)
        }
        let url = try fixture()
        let first = Task { try await loader.load(from: url) }
        try await wait { await gate.count == 1 }
        first.cancel()
        _ = await first.result
        let second = Task { try await loader.load(from: url) }
        try await wait { await gate.count == 2 }
        await gate.releaseAll()
        #expect(try await second.value.report.cachePath == .miss)
        try await wait { await loader.statistics.inFlight == 0 }
        #expect(await loader.statistics.parses == 2)
        #expect(await loader.statistics.retainedMovies == 1)
    }

    /// GPU、系统呈现、零时间和清屏分开计数，seek 后的旧位置不得成为有效完成位置。
    @Test func diagnosticCallbacksRejectStalePositions() async throws {
        let movie = try await SVGALoader().load(from: fixture()).movie
        let player = SVGAPlayer()
        try await player.install(movie)
        let old = await player.testRequest()
        try await player.seek(toFrame: 10)
        let completion = GPUCompletion(succeeded: true, error: nil, seconds: 0.001, observed: Monotonic.now)
        await player.completed(old, result: completion)
        await player.presented(old, time: 1, observed: Monotonic.now)
        #expect(await player.snapshot.gpuCompletedPosition == nil)
        #expect(await player.diagnostics?.stalePresentations == 1)
        let current = await player.testRequest()
        await player.completed(current, result: completion)
        await player.presented(current, time: 0, observed: Monotonic.now)
        #expect(await player.snapshot.gpuCompletedPosition?.frame == 10)
        #expect(await player.diagnostics?.zeroTimeSkips == 1)
        #expect(await player.diagnostics?.systemPresentations == 1)
        #expect(await player.diagnostics?.totalGPUSeconds == 0.002)
        let clear = await player.testRequest(clear: true)
        await player.completed(clear, result: completion)
        #expect(await player.diagnostics?.gpuCompletions == 2)
        for _ in 0..<200 { await player.presented(current, time: 1, observed: Monotonic.now) }
        #expect(await player.diagnostics?.events.count == 128)
        await player.shutdown()
    }

    /// 进入 install 之前已经取消的任务必须回到 empty；不能停在没有后台工作的 preparing。
    @Test func preCancelledInstallationDoesNotRemainPreparing() async throws {
        let movie = try await SVGALoader().load(from: fixture()).movie
        let player = SVGAPlayer()
        let gate = DecodeGate()
        let installation = Task {
            await gate.suspend()
            try await player.install(movie)
        }
        try await wait { await gate.count == 1 }
        installation.cancel()
        await gate.releaseAll()
        await #expect(throws: CancellationError.self) { try await installation.value }
        #expect(await player.snapshot.state == .empty)
        #expect(await player.snapshot.movieIdentity == nil)
        try await player.install(movie)
        #expect(await player.snapshot.state == .paused)
        await player.shutdown()
    }

    /// 夹具直接使用已提交的真实 SVGA 文件，不构造协议二进制。
    private func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "1", withExtension: "svga", subdirectory: "Fixtures"))
    }

    /// 等待可观测状态且限定两秒，超时直接失败而非无限挂住测试进程。
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw SVGAError.invalidOperation("测试等待超时") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// 控制解析暂停点的测试 actor；不改变字节布局，也不生成假影片。
private actor DecodeGate {
    /// 已进入暂停点的解析数量，累计不清零。
    private(set) var count = 0
    /// 每次解析最多等待一次，由测试明确释放全部任务。
    private var pending: [CheckedContinuation<Void, Never>] = []

    /// 暂停后台解析以便主测试发出确定的取消或失效操作。
    func suspend() async {
        count += 1
        await withCheckedContinuation { pending.append($0) }
    }

    /// 一次恢复全部等待者，释放后由真实解码器继续执行或检查取消。
    func releaseAll() {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

/// 测试只构造回调身份，源位置仍取自真实安装；不向生产公开合成器细节。
private extension SVGAPlayer {
    /// 捕获当前安装和代数，模拟驱动异步回调携带的标量身份。
    func testRequest(clear: Bool = false) -> FrameRequest {
        FrameRequest(id: UUID(), installationID: installationID, revision: revision,
                     sequence: sequence, position: timeline?.snapshot(), clear: clear)
    }
}
