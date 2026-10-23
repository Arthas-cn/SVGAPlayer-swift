import CoreGraphics
import Foundation
import simd

/// 缓存后的路径轮廓三角扇；GPU 通过非零 winding stencil 填充，可表达凹形与孔洞。
struct PathGeometry: Sendable {
    /// 每三个顶点构成有方向三角形；不在 CPU 假设轮廓是凸多边形。
    let triangles: [SIMD2<Float>]
    /// 轮廓包围盒，用于 stencil 覆盖和着色。
    let bounds: CGRect
}

/// 一种颜色的几何输入，填充与描边分别构建，避免逐帧重新细分。
struct ColoredGeometry: Sendable {
    /// 已细分轮廓。
    let path: PathGeometry
    /// 尚未乘精灵透明度的源颜色。
    let color: SVGAColor
}

/// 只负责准备矢量几何；无 Metal、平台图层或播放状态依赖。
enum SVGAGeometry {
    /// 创建形状填充和描边；描边由 Core Graphics 转轮廓，再统一走 GPU winding。
    static func prepare(_ shape: MovieShape) throws -> [ColoredGeometry] {
        let path: CGPath
        switch shape.geometry {
        case .path(let text):
            var parser = SVGAPath(text)
            path = try parser.parse()
        case .rectangle(let box, let radius):
            guard radius >= 0 else { throw SVGAError.invalidData("圆角半径为负") }
            path = CGPath(roundedRect: box.cgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse(let box):
            path = CGPath(ellipseIn: box.cgRect, transform: nil)
        }
        var result: [ColoredGeometry] = []
        var transform = shape.transform.affine
        if let color = shape.style.fill, color.alpha > 0, let transformed = path.copy(using: &transform) {
            result.append(ColoredGeometry(path: try flatten(transformed), color: color))
        }
        if let color = shape.style.stroke, color.alpha > 0, shape.style.width > 0 {
            // 先在形状局部空间描边，再应用形状矩阵；否则非均匀缩放会改变源描边语义。
            let dashed = shape.style.dash.isEmpty ? path : path.copy(dashingWithPhase: shape.style.dashOffset,
                                                                     lengths: shape.style.dash.map { CGFloat($0) })
            let caps: [CGLineCap] = [.butt, .round, .square]
            let joins: [CGLineJoin] = [.miter, .round, .bevel]
            let stroked = dashed.copy(strokingWithWidth: shape.style.width,
                                       lineCap: caps[shape.style.cap], lineJoin: joins[shape.style.join],
                                       miterLimit: shape.style.miter)
            if let transformed = stroked.copy(using: &transform) {
                result.append(ColoredGeometry(path: try flatten(transformed), color: color))
            }
        }
        return result
    }

    /// 将裁切路径缓存为同样的几何；空路径交给调用者表示无裁切。
    static func clip(_ text: String) throws -> PathGeometry {
        var parser = SVGAPath(text)
        return try flatten(parser.parse())
    }

    /// 将曲线自适应细分到源坐标约 0.25 点；取消和复杂度上限在轮廓及递归边界检查。
    static func flatten(_ path: CGPath) throws -> PathGeometry {
        var contours: [[CGPoint]] = []
        var current: [CGPoint] = []
        var failure: Error?
        path.applyWithBlock { pointer in
            // CGPath 的遍历回调不可抛出；记录首个错误后停止后续计算，遍历结束统一交还。
            guard failure == nil else { return }
            do {
                try Task.checkCancellation()
                let element = pointer.pointee
                switch element.type {
                case .moveToPoint:
                    if !current.isEmpty { contours.append(current) }
                    current = [element.points[0]]
                case .addLineToPoint:
                    current.append(element.points[0])
                case .addQuadCurveToPoint:
                    if let start = current.last {
                        let control = element.points[0], end = element.points[1]
                        let c1 = CGPoint(x: start.x + (control.x - start.x) * 2 / 3,
                                         y: start.y + (control.y - start.y) * 2 / 3)
                        let c2 = CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                                         y: end.y + (control.y - end.y) * 2 / 3)
                        try subdivide(start, c1, c2, end, depth: 0, into: &current)
                    }
                case .addCurveToPoint:
                    if let start = current.last {
                        try subdivide(start, element.points[0], element.points[1], element.points[2],
                                      depth: 0, into: &current)
                    }
                case .closeSubpath:
                    if !current.isEmpty { contours.append(current); current.removeAll(keepingCapacity: true) }
                @unknown default:
                    throw SVGAError.unsupported("CGPath 元素")
                }
                guard current.count <= 100_000, contours.count <= 10_000 else {
                    throw SVGAError.invalidData("路径复杂度超过上限")
                }
            } catch { failure = error }
        }
        if let failure { throw failure }
        if !current.isEmpty { contours.append(current) }
        var triangles: [SIMD2<Float>] = []
        for contour in contours where contour.count >= 3 {
            try Task.checkCancellation()
            let anchor = SIMD2(Float(contour[0].x), Float(contour[0].y))
            for index in 1..<(contour.count - 1) {
                triangles.append(anchor)
                triangles.append(SIMD2(Float(contour[index].x), Float(contour[index].y)))
                triangles.append(SIMD2(Float(contour[index + 1].x), Float(contour[index + 1].y)))
            }
            guard triangles.count <= 1_000_000 else { throw SVGAError.invalidData("几何顶点超过上限") }
        }
        return PathGeometry(triangles: triangles, bounds: path.boundingBoxOfPath)
    }

    /// 使用 de Casteljau 细分立方曲线；深度上限保证恶意坐标不会无限递归。
    private static func subdivide(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                                  depth: Int, into points: inout [CGPoint]) throws {
        try Task.checkCancellation()
        let dx = p3.x - p0.x, dy = p3.y - p0.y
        let d1 = abs((p1.x - p3.x) * dy - (p1.y - p3.y) * dx)
        let d2 = abs((p2.x - p3.x) * dy - (p2.y - p3.y) * dx)
        let lengthSquared = dx * dx + dy * dy
        // 起终点重合时不能用零长弦判定平坦，改用控制点离起点的距离。
        let flat = lengthSquared > 1e-12
            ? (d1 + d2) * (d1 + d2) <= 0.0625 * lengthSquared
            : max(hypot(p1.x - p0.x, p1.y - p0.y), hypot(p2.x - p0.x, p2.y - p0.y)) <= 0.25
        if flat || depth >= 14 {
            guard points.count < 100_000 else { throw SVGAError.invalidData("曲线细分超过上限") }
            points.append(p3)
            return
        }
        let a = midpoint(p0, p1), b = midpoint(p1, p2), c = midpoint(p2, p3)
        let d = midpoint(a, b), e = midpoint(b, c), middle = midpoint(d, e)
        try subdivide(p0, a, d, middle, depth: depth + 1, into: &points)
        try subdivide(middle, e, c, p3, depth: depth + 1, into: &points)
    }

    /// 计算细分控制点中点，不修改输入几何。
    private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}
