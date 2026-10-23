import Foundation
import Testing
import Metal
@testable import SVGAPlayer_swift

/// 时间轴、真实 Metal 编码及内容替换的回归，不以控制状态替代系统呈现证据。
struct SVGAPlaybackTests {
    /// 浮点余量跨 tick 保留，有限两轮只在真正跨过时间轴末端时完成。
    @Test func timelineCountsNaturalIterations() {
        var timeline = PlaybackTimeline(frameCount: 80, frameRate: 20)
        let completedStep1 = timeline.advance(seconds: 3.95, loop: .finite(2))
        #expect(!completedStep1)
        #expect(timeline.frame == 79)
        #expect(timeline.completedIterations == 0)
        let completedStep2 = timeline.advance(seconds: 0.1, loop: .finite(2))
        #expect(!completedStep2)
        #expect(timeline.completedIterations == 1)
        let completedStep3 = timeline.advance(seconds: 4, loop: .finite(2))
        #expect(completedStep3)
        #expect(timeline.completedIterations == 2)
        #expect(timeline.completedWholeIterations == 2)
        #expect(timeline.frame == 79)
    }

    /// 手动跳到尾部不会增加完整轮数，无限循环的新一轮可重新积累完整播放证据。
    @Test func seekingDoesNotForgeAWholeIteration() {
        var timeline = PlaybackTimeline(frameCount: 80, frameRate: 20)
        timeline.seek(frame: 79)
        let completedStep4 = timeline.advance(seconds: 0.1, loop: .infinite)
        #expect(!completedStep4)
        #expect(timeline.completedIterations == 1)
        #expect(timeline.completedWholeIterations == 0)
        let completedStep5 = timeline.advance(seconds: 4, loop: .infinite)
        #expect(!completedStep5)
        #expect(timeline.completedWholeIterations == 1)
        timeline.rewind()
        #expect(timeline.frame == 0)
        #expect(timeline.completedIterations == 0)
        let completedStep6 = timeline.advance(seconds: .nan, loop: .finite(1))
        #expect(!completedStep6)
    }

    /// 无显示宿主仍可准备和定位，但不能产生虚假的 GPU 完成或系统呈现。
    @Test func headlessPlayerAndContentFailures() async throws {
        let movie = try await fixture("1")
        let player = SVGAPlayer()
        try await player.install(movie)
        #expect(await player.snapshot.state == .paused)
        #expect(await player.snapshot.gpuCompletedPosition == nil)
        #expect(await player.diagnostics?.gpuCompletions == 0)
        #expect(await player.diagnostics?.systemPresentations == nil)
        try await player.seek(toFrame: 17)
        #expect(await player.snapshot.requestedPosition?.frame == 17)
        try await player.seek(toProgress: 1)
        #expect(await player.snapshot.requestedPosition?.frame == 79)
        await #expect(throws: SVGAError.self) { try await player.seek(toFrame: 80) }
        await #expect(throws: SVGAError.self) { try await player.changeLoop(to: .finite(0)) }
        await #expect(throws: SVGAError.self) { try await player.hideSprite(forKey: "missing") }
        await #expect(throws: SVGAError.self) { try await player.replaceImage(with: Data([0, 1, 2]), forKey: "img_18") }
        #expect(await player.snapshot.failure == nil)
        #expect(await player.contentEvents.filter { $0.status == .failed }.count == 2)
        let revision = await player.snapshot.revision
        try await player.replaceText(with: SVGAText("真实 key"), forKey: "img_18")
        #expect(await player.snapshot.revision > revision)
        let textRevision = await player.snapshot.revision
        await #expect(throws: SVGAError.self) {
            try await player.replaceText(with: SVGAText(String(repeating: "a", count: 65_537)), forKey: "img_18")
        }
        #expect(await player.snapshot.revision == textRevision)
        #expect(await player.snapshot.failure == nil)
        try await player.hideSprite(forKey: "img_18")
        try await player.restoreSprite(forKey: "img_18")
        #expect(await player.contentEvents.last?.status == .succeeded)
        await player.shutdown()
        #expect(await player.snapshot.state == .empty)
        #expect(await player.snapshot.movieIdentity == nil)
    }

    /// 真实位图、矢量和 matte 样本能完成 Metal 命令；离屏测试不声明系统呈现或人工画面通过。
    @Test func realSamplesCompleteGPUCommands() async throws {
        let context = try MetalContext.shared.get()
        for name in ["1", "133", "matteRect", "matteBitmap_1.x"] {
            let movie = try await fixture(name)
            let scene = try await MetalMovie.prepare(movie, context: context)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 320, height: 320, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            let target = try #require(context.device.makeTexture(descriptor: descriptor))
            let renderer = MetalRenderer(context: context)
            let submission = try renderer.encode(scene: scene, frame: min(10, movie.frameCount - 1), target: target,
                                                  mode: .aspectFit, scale: 1, content: [:])
            let status = await withCheckedContinuation { continuation in
                submission.commandBuffer.addCompletedHandler { command in
                    continuation.resume(returning: command.status == .completed)
                }
                submission.commandBuffer.commit()
            }
            #expect(status, "\(name) 的 Metal 命令应成功")
            #expect(submission.cpuInputBytes > 0)
        }
    }

    /// 从包内真实资源加载，任何缺失或损坏都让测试失败。
    private func fixture(_ name: String) async throws -> SVGAMovie {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "svga", subdirectory: "Fixtures"))
        return try await SVGALoader().load(from: url).movie
    }
}
