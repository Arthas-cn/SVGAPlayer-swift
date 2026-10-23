import Foundation
import SwiftProtobuf

/// 将 SVGA 1.x movie.spec 规范化到同一模型入口；不自行猜测二进制字段。
/// JSON 键和默认值来自 SVGAVideoEntity、SVGAVideoSpriteFrameEntity、SVGAVectorLayer 的 init/reset 方法。
enum LegacyJSON {
    /// 校验 JSON 结构、附件引用，再交给生成类型解析；取消在精灵循环边界检查。
    static func decode(_ data: Data, assets: [String: Data]) throws -> Com_Opensource_Svga_MovieEntity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let movie = root["movie"] as? [String: Any],
              let box = movie["viewBox"] as? [String: Any],
              let sourceSprites = root["sprites"] as? [[String: Any]] else {
            throw SVGAError.invalidData("movie.spec 缺少 movie/viewBox/sprites")
        }
        let params: [String: Any] = ["viewBoxWidth": box["width"] ?? 100,
                                     "viewBoxHeight": box["height"] ?? 100,
                                     "fps": movie["fps"] ?? 20, "frames": movie["frames"] ?? 0]
        var sprites: [[String: Any]] = []
        for source in sourceSprites {
            try Task.checkCancellation()
            guard let key = source["imageKey"] as? String,
                  let sourceFrames = source["frames"] as? [[String: Any]] else {
                throw SVGAError.invalidData("movie.spec 精灵结构")
            }
            let frames = try sourceFrames.map { source -> [String: Any] in
                var frame: [String: Any] = [:]
                for field in ["alpha", "layout", "transform", "clipPath"] { frame[field] = source[field] }
                if let shapes = source["shapes"] as? [[String: Any]] {
                    frame["shapes"] = try shapes.map(normalizeShape)
                }
                return frame
            }
            var sprite: [String: Any] = ["imageKey": key, "frames": frames]
            sprite["matteKey"] = source["matteKey"]
            sprites.append(sprite)
        }
        let normalized: [String: Any] = ["version": root["ver"] as? String ?? "1.x",
                                          "params": params, "sprites": sprites]
        var proto = try Com_Opensource_Svga_MovieEntity(jsonUTF8Data: JSONSerialization.data(withJSONObject: normalized))
        if let images = root["images"] as? [String: String] {
            for (key, name) in images {
                guard let value = assets[name + ".png"] else { throw SVGAError.invalidData("movie.spec 缺少图片：\(name)") }
                // 与 resetImagesWithJSONObject 一致，JSON 图片 key 去除文件后缀。
                proto.images[(key as NSString).deletingPathExtension] = value
            }
        }
        return proto
    }

    /// 将旧 shape.args 与样式数组转换成官方 protobuf JSON 字段，保持数值原样供后续校验。
    private static func normalizeShape(_ source: [String: Any]) throws -> [String: Any] {
        guard let type = source["type"] as? String,
              let number = ["shape": 0, "rect": 1, "ellipse": 2, "keep": 3][type] else {
            throw SVGAError.unsupported("movie.spec 矢量类型")
        }
        var result: [String: Any] = ["type": number]
        if type != "keep" { result[type] = source["args"] ?? [:] }
        result["transform"] = source["transform"]
        if let sourceStyle = source["styles"] as? [String: Any] {
            var style: [String: Any] = [:]
            for field in ["strokeWidth", "miterLimit"] { style[field] = sourceStyle[field] }
            for field in ["fill", "stroke"] {
                if let color = sourceStyle[field] as? [NSNumber], color.count == 4 {
                    style[field] = Dictionary(uniqueKeysWithValues: zip(["r", "g", "b", "a"], color))
                }
            }
            if let cap = sourceStyle["lineCap"] as? String { style["lineCap"] = ["butt": 0, "round": 1, "square": 2][cap] }
            if let join = sourceStyle["lineJoin"] as? String { style["lineJoin"] = ["miter": 0, "round": 1, "bevel": 2][join] }
            if let dash = sourceStyle["lineDash"] as? [NSNumber], dash.count == 3 {
                style["lineDashI"] = dash[0]
                style["lineDashII"] = dash[1]
                style["lineDashIII"] = dash[2]
            }
            result["styles"] = style
        }
        return result
    }
}
