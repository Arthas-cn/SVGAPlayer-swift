import Foundation
import SVGAPlayer_swift

/// 用户操作的有界日志；仅保留时间和复现参数，不持有像素或 GPU 资源。
nonisolated struct DemoAction: Sendable, Codable, Identifiable {
    /// 每条操作的唯一身份。
    let id: UUID
    /// 人类可读墙钟时间，与库的单调阶段时间分开。
    let date: Date
    /// 操作名称或生命周期阶段。
    let operation: String
    /// 目标精灵 key，非内容操作为 nil。
    let key: String?
    /// 复现参数或错误文本。
    let parameters: String
    /// 创建实际发生的宿主操作，解码时保留原始时间和身份。
    init(_ operation: String, key: String? = nil, parameters: String = "") {
        id = UUID()
        date = Date()
        self.operation = operation
        self.key = key
        self.parameters = parameters
    }
}

/// 报告中的实际环境，不以本次运行时间伪造构建标记。
nonisolated struct DemoEnvironment: Sendable, Codable {
    /// 系统版本的原始文本。
    let system: String
    /// 主机 CPU 架构和逻辑核数，不读取用户设备昵称。
    let cpu: String
    /// Debug 或 Release。
    let configuration: String
    /// Bundle 的真实版本与构建号。
    let build: String
    /// 构建时附带的标记，当前工程未提供时为 nil。
    let artifactMarker: String?

    /// 从当前运行进程与 bundle 捕获环境，供 UI 和 JSON 共用。
    @MainActor static func current() -> DemoEnvironment {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未提供"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未提供"
        return DemoEnvironment(system: ProcessInfo.processInfo.operatingSystemVersionString,
            cpu: "\(architecture) / \(ProcessInfo.processInfo.processorCount) logical CPUs",
            configuration: configuration, build: "\(version) (\(build))",
            artifactMarker: Bundle.main.object(forInfoDictionaryKey: "SVGABuildMarker") as? String)
    }
}

/// 一次实际尝试的机器可读证据；解析、渲染、完整播放与人工画面四者分开。
nonisolated struct DemoResourceReport: Sendable, Codable {
    /// 一次详情或整个批次共用的身份。
    let runID: UUID
    /// 实际候选路径与文件大小。
    let resource: DemoResource
    /// 当前运行环境。
    let environment: DemoEnvironment
    /// 此次尝试的终结原因或手动导出原因。
    let endReason: String
    /// succeeded、failed、cancelled 或 notExecuted。
    let parsing: String
    /// 只有真实 GPU 完成计数大于零时才是 completed。
    let rendering: String
    /// 只有有限轮次自然结束且完整经过一轮才是 finished；预览单列。
    let playback: String
    /// 默认 pending，不根据计数自动写通过。
    let visual: String
    /// 本次加载报告，未开始加载为 nil。
    let load: SVGALoadReport?
    /// 导出瞬间的播放控制快照。
    let snapshot: SVGAPlaybackSnapshot?
    /// 同次安装的渲染快照，未安装成功为 nil。
    let diagnostics: SVGAPlaybackDiagnostics?
    /// 共享缓存的实时统计，计费不是进程 RSS。
    let cache: SVGACacheStatistics?
    /// 最多 128 条宿主操作。
    let actions: [DemoAction]
    /// 最多 256 条内容替换记录。
    let contentEvents: [SVGAContentEvent]
    /// 主错误或本次尝试失败原因。
    let error: String?
}

/// 整批验收报告；计划和已尝试结果分别保留，未运行不会冒充成功。
nonisolated struct DemoBatchReport: Sendable, Codable {
    /// 本轮批次的共同身份。
    let runID: UUID
    /// 稳定顺序的完整计划。
    let planned: [DemoResource]
    /// 只包含实际开始尝试的文件。
    let attempted: [DemoResourceReport]
    /// 是否由用户或页面生命周期取消。
    let cancelled: Bool
    /// 自然完整播放一轮的份数。
    let completedMovies: Int
    /// 已尝试中失败或超时的份数，取消不计为失败。
    let failedMovies: Int
}

/// 只在显式导出、单份完成或批次结束时异步写盘；仅清理本 demo 自己的报告目录。
nonisolated enum DemoReportStore {
    /// 同进程的导出与保留清理统一串行，防止两个宿主导出时相互删除正在写入的 run。
    private static let writer = DemoReportWriter()

    /// 原子写入机器可读 JSON，成功才返回路径，最多保留十个 run 目录。
    static func save<Value: Encodable & Sendable>(_ value: Value, runID: UUID, name: String) async throws -> URL {
        try await writer.save(value, runID: runID, name: name)
    }
}

/// 后台报告写入与淘汰拥有者；一次写入加清理期间不允许另一个导出插入。
private actor DemoReportWriter {
    /// 无暂停点地完成一份原子归档及旧 run 清理，磁盘失败直接交给调用页面。
    func save<Value: Encodable & Sendable>(_ value: Value, runID: UUID, name: String) throws -> URL {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appending(path: "SVGASwiftReports", directoryHint: .isDirectory)
        let directory = root.appending(path: runID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appending(path: name + ".json")
        try encoder.encode(value).write(to: url, options: .atomic)
        let candidates = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
            .filter { $0 != directory && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
        for expired in candidates.dropFirst(9) { try FileManager.default.removeItem(at: expired) }
        return url
    }
}
