import Foundation

/// bundle 中的实际候选文件；损坏文件仍是合法目录条目，解析失败不会把它过滤掉。
nonisolated struct DemoResource: Identifiable, Hashable, Codable, Sendable {
    /// 文件名即列表和启动参数的稳定身份，例如 12.svga。
    let id: String
    /// 实际 bundle 完整路径。
    let url: URL
    /// 扫描时读取的文件字节数。
    let byteCount: Int
    /// 相对资源根目录的路径，不依赖 app 安装位置。
    let relativePath: String

    /// 固化扫描得到的身份与相对路径，使 Codable 报告也包含可跨安装位置复现的路径。
    init(id: String, url: URL, byteCount: Int) {
        self.id = id
        self.url = url
        self.byteCount = byteCount
        relativePath = "resoureces/" + id
    }
}

/// 只扫描目录元数据，不尝试解析影片来决定是否展示。
nonisolated enum DemoResourceCatalog {
    /// 从 bundle 固定资源目录收集所有 .svga；目录不存在或读取失败明确抛错。
    @concurrent static func scan(bundleURL: URL) async throws -> [DemoResource] {
        let directory = bundleURL.appending(path: "resoureces", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var result: [DemoResource] = []
        for url in files where url.pathExtension.lowercased() == "svga" {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue } // 子目录不当成可播放文件，也不递归改变目录身份。
            guard let size = values.fileSize else { throw DemoError.message("无法读取文件大小：\(url.lastPathComponent)") }
            result.append(DemoResource(id: url.lastPathComponent, url: url, byteCount: size))
        }
        return result.sorted {
            let lhs = Int($0.url.deletingPathExtension().lastPathComponent)
            let rhs = Int($1.url.deletingPathExtension().lastPathComponent)
            if let lhs, let rhs, lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
    }
}

/// demo 的诊断性失败，不伪造为库解析错误。
nonisolated enum DemoError: Error, LocalizedError, Sendable {
    /// 宿主或报告操作失败，关联值包含可复现说明。
    case message(String)
    /// 15 秒未观察到首次有效 GPU 完成。
    case firstGPUTimeout
    /// 单份批播超过按源时长计算的截止时间。
    case playbackTimeout
    /// 供界面和报告显示的完整错误原因。
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .firstGPUTimeout: "15 秒内没有首次有效 GPU 完成，请检查宿主挂载和库诊断。"
        case .playbackTimeout: "播放超过两倍源时长加 10 秒（至少 20 秒）的上限。"
        }
    }
}

/// 导航只保存资源值；普通详情与显式双宿主验收分别创建自己的会话。
enum DemoRoute: Hashable {
    /// 单一会话详情。
    case detail(DemoResource)
    /// 同一源文件的独立双会话宿主对照。
    case hosts(DemoResource)
    /// 整个目录的顺序批播，不受搜索过滤影响。
    case batch
}
