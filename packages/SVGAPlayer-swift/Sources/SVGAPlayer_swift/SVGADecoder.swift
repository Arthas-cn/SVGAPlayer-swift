import Foundation
import CoreGraphics
import ImageIO
import SwiftProtobuf

/// 将系统解压输出转为库的不可变模型；protobuf 布局由官方 schema 的生成代码处理。
/// 字段证据：旧 Source/pbobjc/Svga.pbobjc.h/.m；帧语义：SVGAVideoSpriteFrameEntity.m。
enum SVGADecoder {
    /// 完成一次可取消解析；所有资源保存在内存中，失败不返回部分影片。
    static func decode(_ data: Data, identity: String) throws -> SVGAMovie {
        let container = try SVGAContainer.unpack(data)
        let proto: Com_Opensource_Svga_MovieEntity
        do {
            proto = try container.json
                ? LegacyJSON.decode(container.payload, assets: container.assets)
                : Com_Opensource_Svga_MovieEntity(serializedBytes: container.payload)
        } catch is CancellationError { throw CancellationError() }
        catch { throw SVGAError.invalidData("影片载荷：\(error)") }
        try Task.checkCancellation()
        let params = proto.params
        let width = Double(params.viewBoxWidth)
        let height = Double(params.viewBoxHeight)
        guard proto.hasParams, width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 32_768, height <= 32_768, params.fps > 0, params.fps <= 1_000,
              params.frames > 0, params.frames <= 100_000, proto.sprites.count <= 10_000 else {
            throw SVGAError.invalidData("画布、帧率、帧数或精灵数量不合法")
        }
        var images: [String: Data] = [:]
        var audioData: [String: Data] = [:]
        let audioKeys = Set(proto.audios.map(\.audioKey))
        for (key, encoded) in proto.images {
            try Task.checkCancellation()
            var value = encoded
            // resetImagesWithProtoObject 允许 map 值引用 ZIP 附件，先尝试 .png 再尝试原名。
            if let name = String(data: encoded, encoding: .utf8), !container.assets.isEmpty {
                guard let asset = container.assets[name + ".png"] ?? container.assets[name] else {
                    throw SVGAError.invalidData("缺少附件：\(name)")
                }
                value = asset
            }
            if audioKeys.contains(key) || value.starts(with: Data("ID3".utf8)) {
                audioData[key] = value
            } else {
                guard let source = CGImageSourceCreateWithData(value as CFData, nil),
                      CGImageSourceGetCount(source) > 0 else {
                    throw SVGAError.invalidData("无法识别图片：\(key)")
                }
                images[key] = value
            }
        }
        let sprites = try proto.sprites.map { sprite -> SVGASprite in
            try Task.checkCancellation()
            // 旧播放器按影片总帧数推进，但不拒绝精灵的额外尾帧；128/130/131.svga 确实包含此情况。
            guard sprite.frames.count <= 100_000 else {
                throw SVGAError.invalidData("精灵帧数超过安全上限：\(sprite.imageKey)")
            }
            var previous: [MovieShape] = []
            let frames = try sprite.frames.map { source -> SpriteFrame in
                try Task.checkCancellation()
                let alpha = try finite(source.alpha)
                guard (0...1).contains(alpha) else { throw SVGAError.invalidData("透明度超出 0...1") }
                let layout = try rect(source.layout.x, source.layout.y, source.layout.width, source.layout.height)
                let transform = try source.hasTransform ? matrix(source.transform) : MovieTransform()
                // SVGAVectorLayer.isKeepFrame 只看第一个 shape；连续 keep 沿用最近的实际形状。
                let shapes = try source.shapes.first?.type == .keep ? previous : source.shapes.map(shape)
                previous = shapes
                return SpriteFrame(alpha: alpha, layout: layout, transform: transform,
                                   clipPath: source.clipPath, shapes: shapes)
            }
            return SVGASprite(key: sprite.imageKey, matteKey: sprite.matteKey.isEmpty ? nil : sprite.matteKey,
                              frames: frames)
        }
        let keys = Set(sprites.map(\.key))
        for sprite in sprites {
            if let matte = sprite.matteKey, !keys.contains(matte) {
                throw SVGAError.invalidData("遮罩精灵不存在：\(matte)")
            }
        }
        let clips = try proto.audios.map { audio -> SVGAAudioClip in
            guard audio.startFrame >= 0, audio.endFrame >= audio.startFrame,
                  audio.endFrame <= params.frames, audio.startTime >= 0,
                  audioData[audio.audioKey] != nil else { throw SVGAError.invalidData("音频区间或附件无效") }
            return SVGAAudioClip(key: audio.audioKey, startFrame: Int(audio.startFrame),
                                 endFrame: Int(audio.endFrame), startTimeMilliseconds: Int(audio.startTime))
        }
        try Task.checkCancellation()
        return SVGAMovie(identity: identity, version: proto.version, size: CGSize(width: width, height: height),
                         frameRate: Double(params.fps), frameCount: Int(params.frames), sprites: sprites,
                         images: images, audioClips: clips, audioData: audioData,
                         modelBytes: container.payload.count * 3)
    }

    /// 映射已证实的三类矢量；未知类型与不匹配的 oneof 明确失败。
    private static func shape(_ source: Com_Opensource_Svga_ShapeEntity) throws -> MovieShape {
        let geometry: ShapeGeometry
        switch (source.type, source.args) {
        case (.shape, .shape(let path)):
            geometry = .path(path.d)
        case (.rect, .rect(let box)):
            geometry = .rectangle(try rect(box.x, box.y, box.width, box.height), try finite(box.cornerRadius))
        case (.ellipse, .ellipse(let ellipse)):
            let x = try finite(ellipse.x), y = try finite(ellipse.y)
            let rx = try finite(ellipse.radiusX), ry = try finite(ellipse.radiusY)
            guard rx >= 0, ry >= 0 else { throw SVGAError.invalidData("椭圆半径为负") }
            geometry = .ellipse(MovieRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
        default:
            throw SVGAError.unsupported("矢量类型或参数不匹配：\(source.type)")
        }
        let s = source.styles
        let dash = try [finite(s.lineDashI), finite(s.lineDashIi)]
        let width = try finite(s.strokeWidth)
        let miter = try finite(s.miterLimit)
        guard width >= 0, miter >= 0, (0...2).contains(s.lineCap.rawValue),
              (0...2).contains(s.lineJoin.rawValue) else { throw SVGAError.invalidData("描边参数") }
        let style = ShapeStyle(fill: try s.hasFill ? color(s.fill) : nil,
                               stroke: try s.hasStroke ? color(s.stroke) : nil,
                               width: width, cap: s.lineCap.rawValue, join: s.lineJoin.rawValue, miter: miter,
                               dash: dash.contains(where: { $0 > 0 }) ? [max(1, dash[0]), max(0.1, dash[1])] : [],
                               dashOffset: try finite(s.lineDashIii))
        return MovieShape(geometry: geometry, transform: try source.hasTransform ? matrix(source.transform) : MovieTransform(),
                          style: style)
    }

    /// 拒绝 NaN/无穷以及远超画布范围的坐标，避免后续顶点计算溢出。
    private static func finite(_ value: Float) throws -> Double {
        guard value.isFinite, abs(value) <= 100_000_000 else { throw SVGAError.invalidData("非有限或过大数值") }
        return Double(value)
    }

    /// 验证矩形尺寸；零面积合法，后续渲染跳过。
    private static func rect(_ x: Float, _ y: Float, _ width: Float, _ height: Float) throws -> MovieRect {
        let result = try MovieRect(x: finite(x), y: finite(y), width: finite(width), height: finite(height))
        guard result.width >= 0, result.height >= 0 else { throw SVGAError.invalidData("矩形尺寸为负") }
        return result
    }

    /// protobuf 消息存在时采用全部六个实际值；不能把显式零系数改成单位矩阵。
    private static func matrix(_ source: Com_Opensource_Svga_Transform) throws -> MovieTransform {
        try MovieTransform(a: finite(source.a), b: finite(source.b), c: finite(source.c),
                           d: finite(source.d), tx: finite(source.tx), ty: finite(source.ty))
    }

    /// 将四个有限颜色通道限制到有效颜色空间；与平台颜色初始化范围一致。
    private static func color(_ source: Com_Opensource_Svga_ShapeEntity.ShapeStyle.RGBAColor) throws -> SVGAColor {
        try SVGAColor(red: finite(source.r), green: finite(source.g), blue: finite(source.b), alpha: finite(source.a))
    }
}
