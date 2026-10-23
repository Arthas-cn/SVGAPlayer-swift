import Foundation
import CoreGraphics

/// 将已证实的 SVGA 路径命令转为临时 CGPath；仅在准备阶段使用，不创建 CAShapeLayer。
/// 支持集合来自旧 Source/SVGABezierPath.m 的 operate:args:；未实现命令明确失败。
struct SVGAPath {
    /// 当前扫描的 ASCII 路径数据；SVG 数值和命令本身不需要 Unicode。
    private let bytes: [UInt8]
    /// 下一个未读取字节位置。
    private var cursor = 0
    /// 当前构造的路径，只在本解析器内可变。
    private let path = CGMutablePath()
    /// 是否已读到第一个 move，避免无起点曲线。
    private var hasStart = false

    /// 保存源文本；所有合法性检查在 parse 中完成。
    init(_ text: String) { bytes = Array(text.utf8) }

    /// 解析完整路径，允许重复参数和相对坐标；缺参数、未知命令或非有限数值抛出错误。
    mutating func parse() throws -> CGPath {
        var command: UInt8?
        while true {
            skipSeparators()
            if cursor == bytes.count { return path.copy()! }
            try Task.checkCancellation()
            if isLetter(bytes[cursor]) {
                command = bytes[cursor]
                cursor += 1
            }
            guard let op = command else { throw SVGAError.invalidData("SVG 路径缺少命令") }
            let upper = op & 0xdf
            let relative = op >= 97
            guard hasStart || upper == 77 else { throw SVGAError.invalidData("SVG 路径必须以 move 开始") }
            let origin = relative ? path.currentPoint : .zero
            switch upper {
            case 77: // move 后连续坐标按 line 处理，避免把整段路径切成多个子路径。
                let point = try point(relativeTo: origin)
                path.move(to: point)
                hasStart = true
                command = relative ? 108 : 76
            case 76:
                path.addLine(to: try point(relativeTo: origin))
            case 72:
                path.addLine(to: CGPoint(x: try number() + origin.x, y: path.currentPoint.y))
            case 86:
                path.addLine(to: CGPoint(x: path.currentPoint.x, y: try number() + origin.y))
            case 67:
                let first = try point(relativeTo: origin)
                let second = try point(relativeTo: origin)
                let end = try point(relativeTo: origin)
                path.addCurve(to: end, control1: first, control2: second)
            case 81:
                let control = try point(relativeTo: origin)
                path.addQuadCurve(to: try point(relativeTo: origin), control: control)
            case 90:
                path.closeSubpath()
                command = nil
            default:
                throw SVGAError.unsupported("SVG 路径命令：\(UnicodeScalar(op))")
            }
        }
    }

    /// 扫描坐标对；同一条曲线的所有相对参数均基于命令开始时的 currentPoint。
    private mutating func point(relativeTo origin: CGPoint) throws -> CGPoint {
        try CGPoint(x: number() + origin.x, y: number() + origin.y)
    }

    /// SVG 数值支持小数、紧邻负号和科学计数法；不把 e/E 误识别为命令。
    private mutating func number() throws -> Double {
        skipSeparators()
        let start = cursor
        if cursor < bytes.count, bytes[cursor] == 43 || bytes[cursor] == 45 { cursor += 1 }
        var digits = 0
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) { cursor += 1; digits += 1 }
        if cursor < bytes.count, bytes[cursor] == 46 {
            cursor += 1
            while cursor < bytes.count, (48...57).contains(bytes[cursor]) { cursor += 1; digits += 1 }
        }
        guard digits > 0 else { throw SVGAError.invalidData("SVG 路径缺少数值") }
        if cursor < bytes.count, bytes[cursor] == 69 || bytes[cursor] == 101 {
            cursor += 1
            if cursor < bytes.count, bytes[cursor] == 43 || bytes[cursor] == 45 { cursor += 1 }
            let exponentStart = cursor
            while cursor < bytes.count, (48...57).contains(bytes[cursor]) { cursor += 1 }
            guard cursor > exponentStart else { throw SVGAError.invalidData("SVG 指数截断") }
        }
        guard let value = Double(String(decoding: bytes[start..<cursor], as: UTF8.self)),
              value.isFinite, abs(value) <= 100_000_000 else { throw SVGAError.invalidData("SVG 数值无效") }
        return value
    }

    /// 跳过 SVG 空白与逗号分隔符，其他标点不能静默忽略。
    private mutating func skipSeparators() {
        while cursor < bytes.count, [9, 10, 13, 32, 44].contains(bytes[cursor]) { cursor += 1 }
    }

    /// 只识别 ASCII 字母，非法多字节命令在数值/命令校验时失败。
    private func isLetter(_ value: UInt8) -> Bool { (65...90).contains(value) || (97...122).contains(value) }
}
