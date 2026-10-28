import Foundation
import Testing
@testable import SVGAPlayer_swift

/// 使用真实 SVGA 验证两种容器、关键帧模型、缓存与失败/取消报告。
struct SVGALoaderTests {
    /// 从包资源定位固定夹具；不存在时让测试失败，不偷偷跳过。
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "svga", subdirectory: "Fixtures"))
    }

    /// 真实 1.svga 的画布、帧率、总帧数、图片和精灵 key 必须与源载荷一致。
    @Test func bitmapMovieMetadata() async throws {
        let result = try await SVGALoader().load(from: fixture("1"))
        let movie = result.movie
        #expect(movie.size.width == 288)
        #expect(movie.size.height == 288)
        #expect(movie.frameRate == 20)
        #expect(movie.frameCount == 80)
        #expect(movie.duration == 4)
        #expect(movie.images.count == 4)
        #expect(movie.spriteKeys == ["img_18", "img_19", "img_20", "img_21"])
        #expect(movie.sprites.allSatisfy { $0.frameCount == 80 })
        #expect(result.report.status == .succeeded)
        #expect(result.report.sha256?.count == 64)
        #expect(result.report.readSeconds != nil)
        #expect(result.report.digestSeconds != nil)
        #expect(result.report.parseSeconds != nil)
        #expect(result.report.sharedWaitSeconds == nil)
    }

    /// 含大量精灵和矢量的真实样本不丢 key，也不将帧率写死为 20。
    @Test func variedMovies() async throws {
        let loader = SVGALoader()
        let many = try await loader.load(from: fixture("12")).movie
        #expect(many.sprites.count == 68)
        #expect(many.images.count == 9)
        let vector = try await loader.load(from: fixture("133")).movie
        #expect(vector.size.width == 144)
        #expect(vector.frameRate == 30)
        #expect(vector.frameCount == 91)
        #expect(vector.spriteKeys.contains("SVIP11/游戏手柄.vector"))
        #expect(vector.sprites.contains { $0.frames.contains { !$0.shapes.isEmpty } })
    }

    /// ZIP 中 movie.binary 与 movie.spec 都要还原真实影片，不能只支持当前 demo 的 zlib 样本。
    @Test func zipContainers() async throws {
        let binary = try await SVGALoader().load(from: fixture("rose_1.5.0")).movie
        #expect(binary.size.width == 750)
        #expect(binary.frameCount == 60)
        #expect(binary.frameRate == 15)
        #expect(binary.sprites.count == 188)
        #expect(binary.images.count == 26)
        let json = try await SVGALoader().load(from: fixture("matteBitmap_1.x")).movie
        #expect(json.size.width == 400)
        #expect(json.frameCount == 30)
        #expect(json.images.count == 1)
        #expect(json.sprites.contains { $0.matteKey == "dengziqi.matte" })
    }

    /// 真实音频样本将编码音频与图片分离，并保留源帧区间与毫秒偏移。
    @Test func audioMetadata() async throws {
        let movie = try await SVGALoader().load(from: fixture("audio_biling")).movie
        #expect(movie.audioClips.count == 1)
        #expect(movie.audioData.count == 1)
        #expect(movie.images.isEmpty)
        let clip = try #require(movie.audioClips.first)
        #expect(clip.startFrame >= 0)
        #expect(clip.endFrame <= movie.frameCount)
        #expect(movie.audioData[clip.key] != nil)
    }

    /// 命中返回同一不可变影片，未执行解析耗时必须为 nil；重载和绕过有独立诊断。
    @Test func cachePolicies() async throws {
        let loader = SVGALoader()
        let url = try fixture("1")
        let first = try await loader.load(from: url)
        let hit = try await loader.load(from: url)
        #expect(first.movie === hit.movie)
        #expect(hit.report.cachePath == .hit)
        #expect(hit.report.parseSeconds == nil)
        let reload = try await loader.load(from: url, policy: .reload)
        #expect(reload.movie !== first.movie)
        #expect(reload.report.cachePath == .miss)
        let bypass = try await loader.load(from: url, policy: .bypassCache)
        #expect(bypass.movie !== reload.movie)
        #expect(bypass.report.cachePath == .bypassed)
        let stats = await loader.statistics
        #expect(stats.hits == 1)
        #expect(stats.parses == 3)
        #expect(stats.invalidations == 1)
        #expect(stats.retainedMovies == 1)
        await loader.clearCache()
        #expect(await loader.statistics.retainedBytes == 0)
    }

    /// 小预算不留超预算影片，取消不会伪报成功，也不会污染完整缓存。
    @Test func budgetAndCancellation() async throws {
        let loader = SVGALoader(byteLimit: 1)
        let url = try fixture("12")
        _ = try await loader.load(from: url)
        #expect(await loader.statistics.retainedMovies == 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.load(from: url)
        }
        do {
            _ = try await task.value
            Issue.record("预先取消的任务不应成功")
        } catch let failure as SVGALoadFailure {
            #expect(failure.report.status == .cancelled)
            #expect(failure.report.readSeconds == nil)
            #expect(failure.report.parseSeconds == nil)
        }
        #expect(await loader.statistics.cancellations == 1)
    }

    /// 明确损坏的短输入和真实文件截断都必须失败，报告保留错误而不产生部分影片。
    @Test func corruptedInputs() async throws {
        let original = try Data(contentsOf: fixture("1"))
        for bytes in [Data(), Data([0x50, 0x4b, 0, 0]), Data(original.prefix(original.count / 2))] {
            let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".svga")
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                _ = try await SVGALoader().load(from: url)
                Issue.record("损坏输入不应成功")
            } catch let failure as SVGALoadFailure {
                #expect(failure.report.status == .failed)
                #expect(failure.report.error != nil)
                #expect(failure.report.parseSeconds != nil)
            }
        }
    }

    /// 报告与缓存统计能够独立编码，供 demo JSON 导出和后续 Agent 消费。
    @Test func diagnosticsAreCodable() async throws {
        let loader = SVGALoader()
        let result = try await loader.load(from: fixture("1"))
        let data = try JSONEncoder().encode(result.report)
        let decoded = try JSONDecoder().decode(SVGALoadReport.self, from: data)
        #expect(decoded.requestID == result.report.requestID)
        #expect(decoded.status == .succeeded)
        _ = try JSONEncoder().encode(await loader.statistics)
    }
}
