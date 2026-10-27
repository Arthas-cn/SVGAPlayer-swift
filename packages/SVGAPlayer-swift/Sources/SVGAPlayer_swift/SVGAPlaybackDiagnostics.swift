import Foundation

/// 显示适配仅决定画布映射，与循环次数或播放结束策略无关。
public enum SVGADisplayMode: String, CaseIterable, Sendable, Codable {
    /// 保持比例完整显示，空余区域透明。
    case aspectFit
    /// 保持比例填满，超出目标的部分裁切。
    case aspectFill
    /// 两轴独立缩放，可能改变比例。
    case stretch
    /// 使用源逻辑尺寸并居中，不自动缩放。
    case originalSize
}

/// 明确表达循环意图，有限次数必须大于零，不以零表示无限。
public enum SVGALoop: Sendable, Codable, Equatable {
    /// 完整播放指定次数；非正数由播放器拒绝。
    case finite(Int)
    /// 持续循环直到调用方暂停或清空。
    case infinite
}

/// 自然完成全部轮次后留下的画面，与显示适配互不混用。
public enum SVGAEndBehavior: String, Sendable, Codable, CaseIterable {
    /// 保留最后一个仍纳入播放的帧；尾部空帧不作为结束画面。
    case holdLastFrame
    /// 显示第一帧但不继续播放。
    case returnToFirstFrame
    /// 清空显示目标，仍保留影片以供重新播放。
    case clear
}

/// 播放控制状态，不能据此推断像素正确或系统已呈现。
public enum SVGAPlaybackState: String, Sendable, Codable {
    /// 尚未安装影片，或显式清空后。
    case empty
    /// 正在准备图片、几何与音频。
    case preparing
    /// 准备完成但时间轴不推进。
    case paused
    /// 时间轴按单调时钟推进。
    case playing
    /// 有限轮次自然播放完毕。
    case finished
    /// 主准备或播放失败，详情在 failure。
    case failed
}

/// 帧位置与归一化进度同时留证，调用 API 则分别接收整数帧和 Double 进度。
public struct SVGAPosition: Sendable, Codable, Equatable {
    /// 从零开始的源帧序号。
    public let frame: Int
    /// 相对有效播放区间的进度，范围 0...1。1 是最后一个仍播放的帧，不含被跳过的尾部空帧。
    public let progress: Double
    /// 对应源帧起点的秒数。
    public let seconds: Double
}

/// 低频消费的播放值快照，不持有图像、视图或 GPU 对象。
public struct SVGAPlaybackSnapshot: Sendable, Codable {
    /// 贯穿播放器寿命的身份。
    public let playerID: UUID
    /// 每次安装重新分配；尚未安装为 nil。
    public let installationID: UUID?
    /// 当前安装影片摘要；清空后为 nil。
    public let movieIdentity: String?
    /// 控制状态，与系统呈现独立。
    public let state: SVGAPlaybackState
    /// 最近接受的请求位置；未安装为 nil。
    public let requestedPosition: SVGAPosition?
    /// 最近有效 GPU 完成位置；尚未完成为 nil。
    public let gpuCompletedPosition: SVGAPosition?
    /// 源时间轴秒数；未安装为 nil。
    public let duration: Double?
    /// 此次播放已自然完成的轮数，seek/暂停不增加。
    public let completedIterations: Int
    /// 从头连续经过的完整轮数；手动 seek 跳过的轮次不在这里计数。
    public let completedWholeIterations: Int
    /// 当前循环设置。
    public let loop: SVGALoop
    /// 当前结束策略。
    public let endBehavior: SVGAEndBehavior
    /// 当前画布适配。
    public let displayMode: SVGADisplayMode
    /// 内容或定位更新代数，用于辨别旧帧完成。
    public let revision: UInt64
    /// 主播放错误；单项内容替换错误不写入这里。
    public let failure: String?
}

/// 有界帧事件阶段；系统呈现只由 drawable 回调确认。
public enum SVGAFrameStage: String, Sendable, Codable {
    /// 影片或当前帧输入已准备。
    case prepared
    /// 命令缓冲已实际提交。
    case submitted
    /// Metal 命令缓冲完成，不等同于屏幕显示。
    case gpuCompleted
    /// 系统回报非零 presentedTime。
    case presented
    /// 呈现回调时间为零，不能算成功呈现。
    case presentationSkipped
    /// 宿主没有可用 drawable，包括未挂载、隐藏或零尺寸。
    case drawableUnavailable
    /// 平台失去 GPU 提交许可或命令被 notPermitted 拒绝；恢复活动状态后可重绘，不算 GPU 完成。
    case gpuUnavailable
    /// 新请求替换尚未提交的旧请求。
    case coalesced
    /// 过期准备、GPU 完成或帧结果被丢弃。
    case discarded
}

/// 单条帧证据只记录标量和身份；最多保留 128 条。
public struct SVGAFrameEvent: Sendable, Codable {
    /// 阶段类别。
    public let stage: SVGAFrameStage
    /// 单调系统时间，单位秒。
    public let monotonicTime: Double
    /// 对应帧请求身份；整体准备事件为 nil。
    public let requestID: UUID?
    /// 帧序号与进度，整体准备时为 nil。
    public let position: SVGAPosition?
    /// 该阶段耗时；不可测或不适用为 nil。
    public let durationSeconds: Double?
    /// 是否仍属于当前安装与内容代；尚不涉及接收时为 nil。
    public let accepted: Bool?
}

/// 可编码的渲染证据；计数与耗时只在真实阶段发生时更新。
public struct SVGAPlaybackDiagnostics: Sendable, Codable {
    /// 播放器持久身份。
    public let playerID: UUID
    /// 此次影片安装身份。
    public let installationID: UUID
    /// 本次影片的原始摘要。
    public let movieIdentity: String
    /// 准备耗时，未完成时为 nil。
    public internal(set) var preparationSeconds: Double?
    /// 安装开始至首次提交的秒数。
    public internal(set) var firstSubmitSeconds: Double?
    /// 安装开始至首次有效 GPU 完成的秒数。
    public internal(set) var firstGPUCompletionSeconds: Double?
    /// 安装开始至首次有效系统呈现的秒数。
    public internal(set) var firstPresentationSeconds: Double?
    /// 最近一次帧求值与编码的 CPU 耗时。
    public internal(set) var latestFramePreparationSeconds: Double?
    /// 本安装观察到的最大帧准备耗时。
    public internal(set) var maximumFramePreparationSeconds: Double?
    /// 实际 Metal GPU 时间累计；驱动未提供有效时间时保持 nil。
    public internal(set) var totalGPUSeconds: Double?
    /// 已提交命令缓冲数量。
    public internal(set) var submittedCommands = 0
    /// 成功 GPU 完成数量；不包括错误命令缓冲。
    public internal(set) var gpuCompletions = 0
    /// 系统非零呈现数量；未收到有效回调前为 nil。
    public internal(set) var systemPresentations: Int?
    /// 非当前安装/内容代的呈现数量。
    public internal(set) var stalePresentations = 0
    /// 系统回调时间为零的跳过数量。
    public internal(set) var zeroTimeSkips = 0
    /// 新请求合并替换旧请求的次数。
    public internal(set) var coalescedRequests = 0
    /// 过期准备、请求与完成结果被拒绝的次数。
    public internal(set) var discardedResults = 0
    /// 没有取得可用 drawable 的次数。
    public internal(set) var drawableFailures = 0
    /// 后台提交门关闭或系统 notPermitted 拒绝的次数；保留独立证据，不升级为影片失败。
    public internal(set) var gpuUnavailableSkips = 0
    /// 最近帧提交的 CPU 动态输入字节；尚未提交时为 nil。
    public internal(set) var latestCPUInputBytes: Int?
    /// 当前 GPU 输入纹理和几何的留存计费；不是进程 RSS。
    public internal(set) var retainedGPUInputBytes: Int?
    /// 最后 128 条阶段事件，不包含任何大对象。
    public internal(set) var events: [SVGAFrameEvent] = []

    /// 追加阶段并裁剪最旧记录；不输出日志、不触发磁盘写入。
    mutating func append(_ event: SVGAFrameEvent) {
        events.append(event)
        if events.count > 128 { events.removeFirst(events.count - 128) }
    }
}

/// 内容替换的操作种类，精灵 key 单独存储以便复现。
public enum SVGAContentOperation: String, Sendable, Codable {
    /// 将编码图片解码并替换精灵内容。
    case image
    /// 栅格化文本并替换精灵内容。
    case text
    /// 隐藏精灵，包括其矢量与动态内容。
    case hide
    /// 恢复源内容并取消该 key 未完成请求。
    case restore
}

/// 单项内容请求结果；失败不自动终止整段播放。
public enum SVGAContentStatus: String, Sendable, Codable {
    /// 内容已安装并使旧帧失效。
    case succeeded
    /// 解码、栅格化或 key 校验失败，源内容继续有效。
    case failed
    /// 请求被显式撤销。
    case cancelled
    /// 请求完成时已被新内容或安装取代。
    case discarded
}

/// 内容请求的有限证据；最多 256 条，不持有图片或文本栅格数据。
public struct SVGAContentEvent: Sendable, Codable {
    /// 当前内容操作身份。
    public let requestID: UUID
    /// 所属安装身份；无影片时为 nil。
    public let installationID: UUID?
    /// 真实目标精灵 key。
    public let key: String
    /// 用户要求的操作。
    public let operation: SVGAContentOperation
    /// 操作终结状态。
    public let status: SVGAContentStatus
    /// 单调系统时间，单位秒。
    public let monotonicTime: Double
    /// 操作耗时，单位秒。
    public let durationSeconds: Double
    /// 错误或丢弃原因；成功为 nil。
    public let detail: String?
}
