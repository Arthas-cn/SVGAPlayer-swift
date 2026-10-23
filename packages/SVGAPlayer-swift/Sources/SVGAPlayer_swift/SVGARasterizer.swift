import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// 动态文本的可传送输入，避免公开 API 接收 CALayer 或平台可变 attributed string。
public struct SVGAText: Sendable, Hashable {
    /// 要显示的完整文本，允许换行。
    public let string: String
    /// Core Text 字体名称；nil 使用系统字体。
    public let fontName: String?
    /// 源画布坐标中的字号，必须有限且大于零。
    public let fontSize: Double
    /// 文本颜色，透明度在栅格化时合成。
    public let color: SVGAColor

    /// 创建文本描述；实际尺寸和资源预算由替换操作验证，失败只影响该项替换。
    public init(_ string: String, fontSize: Double = 24, fontName: String? = nil,
                color: SVGAColor = SVGAColor(red: 1, green: 1, blue: 1)) {
        self.string = string
        self.fontSize = fontSize
        self.fontName = fontName
        self.color = color
    }
}

/// 一次性 CPU 上传数据；上传完成后释放，不让每帧持有编码图片或重复解码。
struct RasterImage: Sendable {
    /// 实际像素宽度，至少一像素。
    let width: Int
    /// 实际像素高度，至少一像素。
    let height: Int
    /// RGBA8 premultiplied 数据，每行 width * 4 字节。
    let pixels: Data
}

/// 后台栅格化图片和文本，只有准备或动态内容变化时运行。
enum SVGARasterizer {
    /// 单项最大像素数；与压缩字节限制分开，拒绝尺寸炸弹。
    static let maximumPixels = 16_777_216

    /// 解码真实图片一次并规范化为预乘 RGBA8；取消在解码前后和绘制后检查。
    static func image(_ data: Data) throws -> RasterImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels / height else {
            throw SVGAError.resource("图片尺寸无效或超过像素预算")
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw SVGAError.resource("图片解码失败")
        }
        try Task.checkCancellation()
        return try raster(width: width, height: height) { context in
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 在精灵源矩形中排版并居中绘制文本；文本变更以外的帧不再调用 Core Text。
    static func text(_ text: SVGAText, size: CGSize) throws -> RasterImage {
        try Task.checkCancellation()
        guard text.string.utf8.count <= 65_536,
              text.fontSize.isFinite, text.fontSize > 0, text.fontSize <= 4096,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 8192, size.height <= 8192 else { throw SVGAError.resource("文本字号或画布尺寸无效") }
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        guard width <= maximumPixels / height else { throw SVGAError.resource("文本超过像素预算") }
        let font = CTFontCreateWithName((text.fontName ?? ".AppleSystemUIFont") as CFString, text.fontSize, nil)
        let color = CGColor(red: text.color.red, green: text.color.green, blue: text.color.blue, alpha: text.color.alpha)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text.string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
            CGSize(width: width, height: height), nil)
        return try raster(width: width, height: height) { context in
            let box = CGRect(x: 0, y: max(0, (Double(height) - suggested.height) / 2),
                             width: Double(width), height: min(Double(height), ceil(suggested.height)))
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: box, transform: nil), nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
    }

    /// 分配一次 CPU 位图并执行调用者绘制；不在播放回调中调用，不读回 GPU 像素。
    private static func raster(width: Int, height: Int, draw: (CGContext) -> Void) throws -> RasterImage {
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw SVGAError.resource("无法创建栅格化上下文")
            }
            draw(context)
        }
        try Task.checkCancellation()
        return RasterImage(width: width, height: height, pixels: pixels)
    }
}
