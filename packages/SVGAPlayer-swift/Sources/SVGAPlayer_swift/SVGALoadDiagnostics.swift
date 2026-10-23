import Foundation

/// 一次加载的缓存意图，与实际走过的缓存路径分开记录。
public enum SVGALoadPolicy: String, Sendable, Codable {
    /// 允许命中同内容缓存或加入正在进行的解析。
    case useCache
    /// 使同内容旧结果失效，并重新解析；新结果可进入缓存。
    case reload
    /// 独立解析且不读取、不写入共享缓存。
    case bypassCache
}

/// 一次请求最终结果；取消不记为损坏或解析失败。
public enum SVGALoadStatus: String, Sendable, Codable {
    /// 返回完整可共享影片。
    case succeeded
    /// 读取、摘要或解析失败，错误保存在报告中。
    case failed
    /// 调用任务取消，可能发生在任意阶段。
    case cancelled
}

/// 实际采用的缓存路径；未读出内容摘要时不可能确定命中情况。
public enum SVGACachePath: String, Sendable, Codable {
    /// 读取或摘要阶段尚未到达缓存查询。
    case notReached
    /// 相同内容已有完整解析值。
    case hit
    /// 为本次请求启动一次共享解析。
    case miss
    /// 加入其他请求已经启动的相同内容解析。
    case joined
    /// 按调用者意图执行独立解析。
    case bypassed
}

/// 一次加载的可编码证据；nil 耗时代表该阶段未执行，单位均为秒。
public struct SVGALoadReport: Sendable, Codable {
    /// 加载请求身份，不随缓存共享而复用。
    public let requestID: UUID
    /// 本次实际 URL 的路径或完整网络地址。
    public let sourcePath: String
    /// 调用者指定的缓存策略。
    public let policy: SVGALoadPolicy
    /// 实际完成状态。
    public internal(set) var status: SVGALoadStatus = .failed
    /// 原始输入 SHA-256；读取/摘要未完成时为 nil。
    public internal(set) var sha256: String?
    /// 实际缓存路径，读取失败时为 notReached。
    public internal(set) var cachePath: SVGACachePath = .notReached
    /// 读取源数据花费；未执行为 nil。
    public internal(set) var readSeconds: Double?
    /// 内容摘要花费；未执行为 nil。
    public internal(set) var digestSeconds: Double?
    /// 本请求启动的实际解析耗时；命中或加入解析时为 nil。
    public internal(set) var parseSeconds: Double?
    /// 加入共享解析后的等待耗时；其他路径为 nil。
    public internal(set) var sharedWaitSeconds: Double?
    /// 从进入加载到返回结果的总耗时。
    public internal(set) var totalSeconds: Double = 0
    /// 原始输入字节数；读取未完成为 nil。
    public internal(set) var sourceBytes: Int?
    /// 失败描述，成功或取消时通常为 nil。
    public internal(set) var error: String?
}

/// 加载成功的不可变影片和本次诊断，缓存命中也产生独立报告。
public struct SVGALoadResult: Sendable {
    /// 可跨多个播放会话安全共享的影片。
    public let movie: SVGAMovie
    /// 本调用对应的报告，不从全局最近记录推断归属。
    public let report: SVGALoadReport
}

/// 加载失败携带自己的报告，防止并发请求通过“最后一条日志”串台。
public struct SVGALoadFailure: Error, Sendable, LocalizedError {
    /// 失败或取消发生前已经观测到的阶段。
    public let report: SVGALoadReport
    /// 报告中的错误描述；取消单独显示。
    public var errorDescription: String? { report.status == .cancelled ? "SVGA 加载已取消" : report.error }
}

/// 解析缓存累计计数与当前占用；所有读写由 SVGALoader actor 串行维护。
public struct SVGACacheStatistics: Sendable, Codable {
    /// 已完成内容的命中次数。
    public internal(set) var hits = 0
    /// 启动新的可缓存解析次数。
    public internal(set) var misses = 0
    /// 加入其他解析的请求数。
    public internal(set) var shared = 0
    /// 实际启动的解析任务数，包括绕过缓存。
    public internal(set) var parses = 0
    /// 当前尚未完成的实际解析任务数，包括正在响应取消的任务。
    public internal(set) var inFlight = 0
    /// 因计费预算淘汰的已缓存影片数。
    public internal(set) var evictions = 0
    /// 显式清理或重新解析所失效的缓存/在途代数。
    public internal(set) var invalidations = 0
    /// 已失效任务的迟到完成次数。
    public internal(set) var discardedResults = 0
    /// 对调用者返回失败的次数，不包含取消。
    public internal(set) var failures = 0
    /// 对调用者返回取消的次数。
    public internal(set) var cancellations = 0
    /// 当前完整缓存的影片份数。
    public internal(set) var retainedMovies = 0
    /// 当前解析值计费字节；不包括 GPU 或进程其他内存。
    public internal(set) var retainedBytes = 0
    /// 解析缓存字节预算上限，单份超过此值仍可返回但不留缓存。
    public internal(set) var byteLimit: Int
}

/// 使用单调时间测量阶段，避免系统墙钟调整污染耗时。
enum Monotonic {
    /// 从系统启动计的秒数，仅用于同一进程内相对比较。
    static var now: Double { ProcessInfo.processInfo.systemUptime }
}
