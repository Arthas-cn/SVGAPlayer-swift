import Foundation

/// 纯值时间轴；不接触显示目标、音频或系统时钟，便于独立验证边界。
struct PlaybackTimeline {
    /// 源时间轴总帧数，初始化时由解析层保证正数。手动 seek 仍可落到被跳过的尾部空帧。
    let frameCount: Int
    /// 默认播放帧数，含起点、不含尾部空帧。循环、自然结束和进度 1 都用这个长度。
    let playbackFrameCount: Int
    /// 源帧率，单位 fps。
    let frameRate: Double
    /// 包含子帧余量的位置，暂停后继续保留余量。
    var position = 0.0
    /// 已自然跨过播放区间末端的轮数。尾部空帧不计入这一轮的长度。
    var completedIterations = 0
    /// 当前轮次是否从头连续经过，手动 seek 后为 false。
    var wholeIteration = true
    /// 真正从头连续走完的轮数，供验收区分手动跳转后的结束。
    var completedWholeIterations = 0

    /// 当前有效帧序号，不返回 frameCount 越界值。停在尾部空帧时仍返回该源帧。
    var frame: Int { min(frameCount - 1, max(0, Int(position))) }

    /// 用源帧数建立时间轴；省略播放帧数时不裁尾。传入的播放帧数会被收进 1...frameCount。
    init(frameCount: Int, frameRate: Double, playbackFrameCount: Int? = nil) {
        self.frameCount = frameCount
        self.frameRate = frameRate
        let proposed = playbackFrameCount ?? frameCount
        // 播放区间必须落在源时间轴内；传入 0 或过大时不能把已有帧的影片收成零帧。
        self.playbackFrameCount = frameCount > 0 ? min(frameCount, max(1, proposed)) : max(0, proposed)
    }

    /// 按经过秒数推进，返回有限循环是否自然结束；负数或非有限间隔不推进。
    /// 越过播放区间末端即一轮结束，尾部空帧不占用播放时间。
    mutating func advance(seconds: Double, loop: SVGALoop) -> Bool {
        guard seconds.isFinite, seconds > 0, playbackFrameCount > 0 else { return false }
        // 手动 seek 已经停在空帧尾部时，本轮剩余时间为零，从播放区间末端继续算。
        let start = min(position, Double(playbackFrameCount))
        let next = start + seconds * frameRate
        guard next.isFinite, next < Double(Int.max / 2) else { return false }
        let crossed = Int(next / Double(playbackFrameCount))
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
            position = Double(playbackFrameCount - 1)
            return true
        }
        position = next.truncatingRemainder(dividingBy: Double(playbackFrameCount))
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

    /// 输出帧、进度、秒数值。进度相对播放区间，1 是最后一帧有效内容；单帧影片的进度为零。
    func snapshot() -> SVGAPosition {
        let span = playbackFrameCount - 1
        let progress = span > 0 ? Double(min(frame, span)) / Double(span) : 0
        return SVGAPosition(frame: frame, progress: progress, seconds: Double(frame) / frameRate)
    }
}
