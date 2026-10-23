import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SVGAPlayer_swift

/// 动态文本上传前的像素方向回归；测试读取的是 CPU 栅格化输入，不从播放 GPU 读回。
struct SVGARasterizerTests {
    /// 非对称大写 F 的上部横笔必须位于纹理顶部，防止 Core Text 坐标导致上下倒置。
    @Test func textHasAnUprightTopRow() throws {
        let image = try SVGARasterizer.text(SVGAText("F", fontSize: 70, fontName: "Helvetica",
            color: SVGAColor(red: 0, green: 0, blue: 0)), size: CGSize(width: 100, height: 100))
        var rows = [Int](repeating: 0, count: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width { rows[y] += Int(image.pixels[(y * image.width + x) * 4 + 3]) }
        }
        let top = try #require(rows.firstIndex(where: { $0 > 0 }))
        let bottom = try #require(rows.lastIndex(where: { $0 > 0 }))
        let middle = (top + bottom) / 2
        #expect(rows[top...middle].reduce(0, +) > rows[(middle + 1)...bottom].reduce(0, +))
        // 仅显式设置时导出测试输入，便于目视核对文字；生产播放器没有这条出图路径。
        if let directory = ProcessInfo.processInfo.environment["SVGA_TEST_ARTIFACTS"] {
            try save(image, to: URL(fileURLWithPath: directory).appending(path: "text-F.png"))
        }
    }

    /// 诊断性栅格输入存成 PNG，使用 RGBA 的原始行顺序，不能额外翻转掩盖测试失败。
    private func save(_ raster: RasterImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let provider = try #require(CGDataProvider(data: raster.pixels as CFData))
        let image = try #require(CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: raster.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
