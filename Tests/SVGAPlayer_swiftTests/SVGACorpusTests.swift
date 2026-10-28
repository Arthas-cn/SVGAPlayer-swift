import Foundation
import Testing
@testable import SVGAPlayer_swift

/// 仓库现有完整样本的解析与几何回归；只读 demo 资源，不在测试中伪造合法二进制。
struct SVGACorpusTests {
    /// 全量样本属于仓库 demo，独立分发 SPM 包时只运行包内真实夹具测试。
    private static var directory: URL {
        var root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        // 源文件在 Tests/SVGAPlayer_swiftTests。只退三级到仓库根；再多退会离开仓库，完整目录回归会被静默跳过。
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root.appending(path: "SVGAPlayer-swift-demo/SVGAPlayer-swift-demo/resoureces")
    }

    /// 逐个解析仓库全部真实样本，并缓存准备每种矢量；失败必须指出具体文件。
    @Test(.enabled(if: FileManager.default.fileExists(atPath: SVGACorpusTests.directory.path),
                   "完整目录回归需本仓库 demo；包内夹具始终独立运行"))
    func bundledCorpusParsesAndPreparesGeometry() async throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "svga" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        // 原始 133 个样本必须仍在；新增真实资源也参加下方全量解析，不能因目录增长而误报失败。
        #expect(files.count >= 133)
        let loader = SVGALoader(byteLimit: 0)
        for file in files {
            do {
                let movie = try await loader.load(from: file).movie
                var shapes = Set<MovieShape>()
                var clips = Set<String>()
                for sprite in movie.sprites {
                    for frame in sprite.frames {
                        shapes.formUnion(frame.shapes)
                        if !frame.clipPath.isEmpty { clips.insert(frame.clipPath) }
                    }
                }
                for shape in shapes { _ = try SVGAGeometry.prepare(shape) }
                for clip in clips { _ = try SVGAGeometry.clip(clip) }
            } catch {
                Issue.record("\(file.lastPathComponent)：\(error)")
            }
        }
    }

    /// 连续相对坐标和科学计数法正确分词；不支持的命令和截断参数不能静默吞掉。
    @Test func pathGrammarAndFailures() throws {
        var parser = SVGAPath("M 1e1,10 l10 0 0 10 -10 0 z")
        let path = try parser.parse()
        #expect(path.boundingBoxOfPath.width == 10)
        #expect(path.boundingBoxOfPath.height == 10)
        #expect(try SVGAGeometry.flatten(path).triangles.count > 0)
        #expect(throws: SVGAError.self) {
            var invalid = SVGAPath("M0 0 C 1 2")
            _ = try invalid.parse()
        }
        #expect(throws: SVGAError.self) {
            var unsupported = SVGAPath("M0 0 A1 1 0 0 0 1 1")
            _ = try unsupported.parse()
        }
    }
}
