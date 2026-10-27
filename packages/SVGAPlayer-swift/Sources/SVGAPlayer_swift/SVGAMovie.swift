import Foundation
import CoreGraphics

/// 可跨会话共享的不可变影片；只保存解析值，不持有播放器、平台视图或 GPU 资源。
public final class SVGAMovie: Sendable {
    /// 原始文件内容的 SHA-256；相同内容可复用解析结果。
    public let identity: String
    /// 源文件版本文本；不由文件扩展名推断版本。
    public let version: String
    /// 逻辑画布尺寸，两轴均大于零。
    public let size: CGSize
    /// 每秒帧数，解析时要求有限且大于零。
    public let frameRate: Double
    /// 源时间轴总帧数，至少一帧。
    public let frameCount: Int
    /// 按源绘制顺序排列的精灵；同名 key 可能有多个实例。
    public let sprites: [SVGASprite]
    /// 已校验容器中的图片编码数据；实际像素解码由准备层完成一次。
    public let images: [String: Data]
    /// 按帧对齐的音频片段，不进入 GPU。
    public let audioClips: [SVGAAudioClip]
    /// 音频 key 到原始编码数据的映射。
    public let audioData: [String: Data]
    /// 解析缓存保守计费，包含编码资源和模型估算；不是进程 RSS。
    public let accountedBytes: Int

    /// 源时间轴总秒数，不随循环设置变化。
    public var duration: Double { Double(frameCount) / frameRate }
    /// 默认播放帧数。尾部连续空帧不计入；全片都空，或音频结束帧仍落在尾部时，保持源帧数。
    /// 证据：SVGAPlayer-Lite `SVGAPlayer.effectivePlaybackRange`。动态替换不重算，安装时按影片自身资源确定。
    public var playbackFrameCount: Int {
        guard frameCount > 0 else { return 0 }
        var lastMeaningful = lastFrameIndexWithRenderableContent()
        // 整段都没有可绘制内容时保留声明长度，避免空素材被收成零帧。
        if lastMeaningful < 0 { lastMeaningful = frameCount - 1 }
        // 音频结束帧也占着时间轴；视觉上为空的尾部只要还挂着这段音频就不能裁掉。
        for clip in audioClips {
            lastMeaningful = max(lastMeaningful, min(clip.endFrame, frameCount - 1))
        }
        return lastMeaningful + 1
    }
    /// 真实精灵 key 的稳定去重目录，供内容替换使用。
    public var spriteKeys: [String] { Array(Set(sprites.map(\.key).filter { !$0.isEmpty })).sorted() }

    /// 从最后一帧往前找仍可绘制的帧；每一帧都空时返回 -1。
    private func lastFrameIndexWithRenderableContent() -> Int {
        for index in stride(from: frameCount - 1, through: 0, by: -1) {
            if sprites.contains(where: { spriteHasRenderableContent($0, at: index) }) { return index }
        }
        return -1
    }

    /// 该精灵在这一帧是否算可见内容。下标超出精灵帧数组时直接视为没有，不能套用渲染层停在末帧的钳制。
    private func spriteHasRenderableContent(_ sprite: SVGASprite, at index: Int) -> Bool {
        guard sprite.frames.indices.contains(index) else { return false }
        return frameHasRenderableContent(sprite.frames[index], key: sprite.key)
    }

    /// 透明度不大于 0.001，或既没有矢量也没有对应位图时，这一帧对该精灵是空的。
    private func frameHasRenderableContent(_ frame: SpriteFrame, key: String) -> Bool {
        if frame.alpha <= 0.001 { return false }
        if !frame.shapes.isEmpty { return true }
        if key.isEmpty { return false }
        let bitmapKey = (key as NSString).deletingPathExtension
        return images[bitmapKey] != nil || images[key] != nil
    }

    /// 仅解析层构建已验证的影片；调用方通过 SVGALoader 获取。
    init(identity: String, version: String, size: CGSize, frameRate: Double, frameCount: Int,
         sprites: [SVGASprite], images: [String: Data], audioClips: [SVGAAudioClip],
         audioData: [String: Data], modelBytes: Int) {
        self.identity = identity
        self.version = version
        self.size = size
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.sprites = sprites
        self.images = images
        self.audioClips = audioClips
        self.audioData = audioData
        accountedBytes = modelBytes + images.values.reduce(0) { $0 + $1.count }
            + audioData.values.reduce(0) { $0 + $1.count }
    }
}

/// 源绘制序列中的一个精灵；帧数据只供库内求值，不暴露图层实现。
public struct SVGASprite: Sendable {
    /// 源 imageKey 原文，也用于动态内容定位。
    public let key: String
    /// 对应遮罩精灵的 key；nil 表示无需精灵遮罩。
    public let matteKey: String?
    /// 精灵实际帧数量，可能少于或多于影片总帧数；播放范围仍以影片时间轴为准。
    public var frameCount: Int { frames.count }
    /// 源帧值；keep 已在解析阶段展开为共享的值数组。
    let frames: [SpriteFrame]
}

/// 音频在影片帧区间内播放的不可变描述；startTime 以毫秒表示源音频偏移。
public struct SVGAAudioClip: Sendable, Codable {
    /// 关联 audioData 的真实 key。
    public let key: String
    /// 开始播放的影片帧序号，包含此帧。
    public let startFrame: Int
    /// 停止播放的影片帧序号，不包含此帧。
    public let endFrame: Int
    /// 音频自身的起播偏移，单位毫秒。
    public let startTimeMilliseconds: Int
}

/// 解析层使用的二维矩形，不把 CGRect 的平台编码格式带入内部缓存键。
struct MovieRect: Sendable, Hashable {
    /// 局部坐标左边界，可为负。
    var x: Double = 0
    /// 局部坐标上边界，可为负。
    var y: Double = 0
    /// 局部宽度，不允许负数。
    var width: Double = 0
    /// 局部高度，不允许负数。
    var height: Double = 0
    /// 供几何准备层使用的 Core Graphics 矩形。
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// 源二维仿射变换；无 transform 消息时使用单位矩阵。
struct MovieTransform: Sendable, Hashable {
    /// x 对 x 的线性系数。
    var a: Double = 1
    /// x 对 y 的线性系数。
    var b: Double = 0
    /// y 对 x 的线性系数。
    var c: Double = 0
    /// y 对 y 的线性系数。
    var d: Double = 1
    /// 水平方向平移，单位为源画布点。
    var tx: Double = 0
    /// 垂直方向平移，单位为源画布点。
    var ty: Double = 0
    /// 供路径与顶点变换使用的矩阵。
    var affine: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

/// 每个精灵的单帧状态；对应旧 SVGAVideoSpriteFrameEntity 的值语义。
struct SpriteFrame: Sendable {
    /// 不透明度，合法范围 0...1。
    let alpha: Double
    /// 位图的源约束矩形。
    let layout: MovieRect
    /// 局部到影片坐标的变换。
    let transform: MovieTransform
    /// SVG 裁切路径；空串表示无局部裁切。
    let clipPath: String
    /// 已消解 keep 语义的矢量列表。
    let shapes: [MovieShape]
}

/// 矢量内容描述；几何准备层可按值缓存细分结果。
struct MovieShape: Sendable, Hashable {
    /// 图形轮廓，不含样式或精灵变换。
    let geometry: ShapeGeometry
    /// 图形自身的局部变换，在精灵变换之前应用。
    let transform: MovieTransform
    /// 填充、描边与线段设置。
    let style: ShapeStyle
}

/// SVGA 证实支持的三类矢量轮廓；keep 只在解析时处理，不进入渲染层。
enum ShapeGeometry: Sendable, Hashable {
    /// SVG 路径字符串，对应 ShapeArgs.d。
    case path(String)
    /// 圆角矩形，关联值为边界与圆角半径。
    case rectangle(MovieRect, Double)
    /// 椭圆外接矩形，由中心和两轴半径换算。
    case ellipse(MovieRect)
}

/// 归一化 RGBA 分量；源文件和替换文本共用，值应在 0...1。
public struct SVGAColor: Sendable, Codable, Hashable {
    /// 红色分量。
    public let red: Double
    /// 绿色分量。
    public let green: Double
    /// 蓝色分量。
    public let blue: Double
    /// 不透明度分量。
    public let alpha: Double

    /// 创建 RGBA 值；非有限分量归零，有限分量钳制到 0...1。
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.isFinite ? min(1, max(0, red)) : 0
        self.green = green.isFinite ? min(1, max(0, green)) : 0
        self.blue = blue.isFinite ? min(1, max(0, blue)) : 0
        self.alpha = alpha.isFinite ? min(1, max(0, alpha)) : 0
    }
}

/// 路径填充和描边参数；原始 enum 数值以 Svga.pbobjc.h 的 ShapeStyle 为准。
struct ShapeStyle: Sendable, Hashable {
    /// nil 表示不填充。
    var fill: SVGAColor?
    /// nil 表示不描边。
    var stroke: SVGAColor?
    /// 描边宽度，零表示没有描边面积。
    var width: Double = 0
    /// 0 butt、1 round、2 square。
    var cap: Int = 0
    /// 0 miter、1 round、2 bevel。
    var join: Int = 0
    /// 尖角长度限制。
    var miter: Double = 0
    /// 虚线长度与间隔；空数组表示实线。
    var dash: [Double] = []
    /// 虚线起始偏移。
    var dashOffset: Double = 0
}

/// 可编码的库错误；取消通过独立的 CancellationError / 加载状态报告。
public enum SVGAError: Error, Sendable, Codable, LocalizedError, Equatable {
    /// 输入损坏或关键参数不合法；关联文本指出失败阶段。
    case invalidData(String)
    /// 输入采用尚未实现的特性；不静默画出不完整内容。
    case unsupported(String)
    /// 文件、图像、音频或 GPU 准备失败。
    case resource(String)
    /// 播放命令不满足前置条件。
    case invalidOperation(String)

    /// 面向诊断与调用方的原始错误描述。
    public var errorDescription: String? {
        switch self {
        case .invalidData(let text): "SVGA 数据损坏：\(text)"
        case .unsupported(let text): "SVGA 尚未支持：\(text)"
        case .resource(let text): "SVGA 资源错误：\(text)"
        case .invalidOperation(let text): "SVGA 操作无效：\(text)"
        }
    }
}
