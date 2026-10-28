import CoreGraphics
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

    /// 官方 Rocket.svga 引用了三个不存在的遮罩精灵；解析必须成功，且编码不能因缺失遮罩失败。
    @Test func rocketWithDanglingMatteStillEncodes() async throws {
        // 源文件在 Tests/SVGAPlayer_swiftTests。只退三级到仓库根；再多退会离开仓库，Rocket.svga 就找不到。
        let rocket = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SVGAPlayer-swift-demo/SVGAPlayer-swift-demo/resoureces/Rocket.svga")
        let movie = try await SVGALoader().load(from: rocket).movie
        #expect(movie.sprites.contains { $0.matteKey == "matte_bTTCW1wT.matte" })
        #expect(movie.sprites.contains { $0.key == "matte_bTTCW1wT.matte" } == false)
        let context = try MetalContext.shared.get()
        let scene = try await MetalMovie.prepare(movie, context: context)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 320, height: 180, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(context.device.makeTexture(descriptor: descriptor))
        let submission = try MetalRenderer(context: context).encode(scene: scene, frame: 0, target: target,
                                                                     mode: .aspectFit, scale: 1, content: [:])
        let status = await withCheckedContinuation { continuation in
            submission.commandBuffer.addCompletedHandler { command in
                continuation.resume(returning: command.status == .completed)
            }
            submission.commandBuffer.commit()
        }
        #expect(status)
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

/// 尾部空帧裁剪：只缩短默认播放区间，源 frameCount 和显式整数帧定位仍保留。
struct SVGATrailingEmptyFrameTests {
    /// 尾部连续透明帧被跳过，夹在中间的空帧仍留在播放区间里。
    @Test func trailingTransparentFramesAreExcluded() {
        let movie = makeMovie(frameCount: 5, frames: [
            sample(alpha: 1), sample(alpha: 0), sample(alpha: 1), sample(alpha: 0), sample(alpha: 0.001),
        ])
        #expect(movie.frameCount == 5)
        #expect(movie.playbackFrameCount == 3)
    }

    /// 没有位图也没有矢量的尾帧会被跳过；去后缀后能对上的位图，以及不带图片的矢量，都算有内容。
    @Test func bitmapAndVectorFramesCountAsContent() {
        let unmatched = makeMovie(frameCount: 2, key: "hero.png",
                                  frames: [sample(alpha: 1, shapes: true), sample(alpha: 1)],
                                  images: ["other": Data([1])])
        #expect(unmatched.playbackFrameCount == 1)
        let bitmap = makeMovie(frameCount: 2, key: "hero.png",
                               frames: [sample(alpha: 1, shapes: true), sample(alpha: 1)],
                               images: ["hero": Data([1])])
        #expect(bitmap.playbackFrameCount == 2)
        let vector = makeMovie(frameCount: 2, frames: [sample(alpha: 1, shapes: true), sample(alpha: 0)], images: [:])
        #expect(vector.playbackFrameCount == 1)
    }

    /// 精灵帧数组比影片短时，缺掉的尾帧不算内容，不能沿用末帧状态把它们留在播放里。
    @Test func framesMissingFromSpriteAreTrailingEmpty() {
        let movie = makeMovie(frameCount: 4, frames: [sample(alpha: 1), sample(alpha: 1)], images: ["img": Data([1])])
        #expect(movie.playbackFrameCount == 2)
    }

    /// 每一帧都不可绘制时保留声明帧数；音频结束帧会把已经裁掉的视觉尾部加回来。
    @Test func fullyEmptyMovieAndAudioTailStayPlayable() {
        let empty = makeMovie(frameCount: 4, frames: [sample(alpha: 0), sample(alpha: 0), sample(alpha: 0), sample(alpha: 0)],
                              images: ["img": Data([1])])
        #expect(empty.playbackFrameCount == 4)
        let voiced = makeMovie(frameCount: 6, frames: [sample(alpha: 1), sample(alpha: 0), sample(alpha: 0),
                                                       sample(alpha: 0), sample(alpha: 0), sample(alpha: 0)],
                               images: ["img": Data([1])],
                               audio: [SVGAAudioClip(key: "a", startFrame: 0, endFrame: 4, startTimeMilliseconds: 0)])
        #expect(voiced.playbackFrameCount == 5)
    }

    /// 自然播放在最后一帧有效内容结束；手动 seek 到空帧后，下一次推进从播放区间起点重新计轮。
    @Test func timelineStopsBeforeTrailingEmptyFrames() {
        var timeline = PlaybackTimeline(frameCount: 10, frameRate: 20, playbackFrameCount: 8)
        let stillInside = timeline.advance(seconds: 7.9 / 20, loop: .finite(1))
        #expect(!stillInside)
        #expect(timeline.frame == 7)
        let finished = timeline.advance(seconds: 0.2 / 20, loop: .finite(1))
        #expect(finished)
        #expect(timeline.frame == 7)
        #expect(timeline.snapshot().progress == 1)

        var seeked = PlaybackTimeline(frameCount: 10, frameRate: 20, playbackFrameCount: 8)
        seeked.seek(frame: 9)
        #expect(seeked.frame == 9)
        let wrapped = seeked.advance(seconds: 0.01, loop: .infinite)
        #expect(!wrapped)
        #expect(seeked.completedIterations == 1)
        #expect(seeked.frame == 0)
    }

    /// 组装只含帧可见性的影片；画布和帧率不参与空帧判断。
    private func makeMovie(frameCount: Int, key: String = "img", frames: [SpriteFrame],
                           images: [String: Data] = ["img": Data([1])], audio: [SVGAAudioClip] = []) -> SVGAMovie {
        SVGAMovie(identity: "empty-frame", version: "2.0", size: CGSize(width: 8, height: 8),
                  frameRate: 20, frameCount: frameCount,
                  sprites: [SVGASprite(key: key, matteKey: nil, frames: frames)],
                  images: images, audioClips: audio, audioData: [:], modelBytes: 0)
    }

    /// 单帧样本。shapes 为真时放一条路径，用来区分“有矢量”和“只有透明位图槽位”。
    private func sample(alpha: Double, shapes: Bool = false) -> SpriteFrame {
        let geometry = shapes ? [MovieShape(geometry: .path("M0 0"), transform: MovieTransform(),
                                            style: ShapeStyle(fill: nil, stroke: nil))] : []
        return SpriteFrame(alpha: alpha, layout: MovieRect(width: 1, height: 1), transform: MovieTransform(),
                           clipPath: "", shapes: geometry)
    }
}
