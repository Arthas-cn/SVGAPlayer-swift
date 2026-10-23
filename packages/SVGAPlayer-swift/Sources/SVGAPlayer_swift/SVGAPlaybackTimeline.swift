import Foundation

/// 纯值时间轴；不接触显示目标、音频或系统时钟，便于独立验证边界。
struct PlaybackTimeline {
    /// 源时间轴总帧数，初始化时由解析层保证正数。
    let frameCount: Int
    /// 源帧率，单位 fps。
    let frameRate: Double
    /// 包含子帧余量的位置，暂停后继续保留余量。
    var position = 0.0
    /// 已自然跨过源时间轴末端的轮数。
    var completedIterations = 0
    /// 当前轮次是否从头连续经过，手动 seek 后为 false。
    var wholeIteration = true
    /// 真正从头连续走完的轮数，供验收区分手动跳转后的结束。
    var completedWholeIterations = 0

    /// 当前有效帧序号，不返回 frameCount 越界值。
    var frame: Int { min(frameCount - 1, max(0, Int(position))) }

    /// 按经过秒数推进，返回有限循环是否自然结束；负数或非有限间隔不推进。
    mutating func advance(seconds: Double, loop: SVGALoop) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        let next = position + seconds * frameRate
        guard next.isFinite, next < Double(Int.max / 2) else { return false }
        let crossed = Int(next / Double(frameCount))
        if crossed == 0 { position = next; return false }
        let remaining: Int
        switch loop {
        case .infinite: remaining = crossed
        case .finite(let count): remaining = min(crossed, max(0, count - completedIterations))
        }
        if remaining > 0 {
            completedIterations += remaining
            completedWholeIterations += remaining - (wholeIteration ? 0 : 1)
            wholeIteration = true
        }
        if case .finite(let count) = loop, completedIterations >= count {
            position = Double(frameCount - 1)
            return true
        }
        position = next.truncatingRemainder(dividingBy: Double(frameCount))
        return false
    }

    /// 跳到已验证的整数帧；手动定位不能冒充完整观看了一轮。
    mutating func seek(frame: Int) {
        position = Double(frame)
        wholeIteration = frame == 0
    }

    /// 重新从第一帧开始计轮；只重置控制值，不声称 GPU 或系统同步完成。
    mutating func rewind() {
        position = 0
        completedIterations = 0
        completedWholeIterations = 0
        wholeIteration = true
    }

    /// 输出帧、进度、秒数值；单帧影片的可定位进度为零。
    func snapshot() -> SVGAPosition {
        SVGAPosition(frame: frame, progress: frameCount > 1 ? Double(frame) / Double(frameCount - 1) : 0,
                     seconds: Double(frame) / frameRate)
    }
}
