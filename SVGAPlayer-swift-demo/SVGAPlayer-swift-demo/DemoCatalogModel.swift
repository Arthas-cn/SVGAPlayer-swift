import Foundation
import Observation
import SVGAPlayer_swift

/// 目录及全部行预览的拥有者；不设置播放器名额，也不按滚动可见性卸载会话。
@MainActor @Observable final class DemoCatalogModel {
    /// 扫描得到的全部候选，搜索不修改此集合。
    private(set) var resources: [DemoResource] = []
    /// 每个真实候选对应的长期预览会话。
    private(set) var previews: [String: DemoSession] = [:]
    /// 扫描失败显式展示，不能用空列表掩盖。
    private(set) var error: String?
    /// 防止用户连续刷新同时写目录。
    private(set) var isScanning = false
    /// 搜索只影响列表显示。
    var query = ""
    /// 用户实际进入列表后开始全部预览；启动参数直达详情无需先创建隐藏目录会话。
    private var previewsStarted = false
    /// 每个候选的任务，刷新时仅移除已不在目录中的项。
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    /// 应用销毁时撤销所有预览；滚动离屏不会触发此路径。
    isolated deinit { for task in tasks.values { task.cancel() } }

    /// 基于文件名的搜索结果，身份保持不变。
    var filtered: [DemoResource] {
        query.isEmpty ? resources : resources.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }

    /// 刷新与系统下拉刷新共用真正的 bundle 扫描，不复用写死列表。
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            guard let root = Bundle.main.resourceURL else { throw DemoError.message("Bundle 没有资源根目录") }
            let next = try await DemoResourceCatalog.scan(bundleURL: root)
            let ids = Set(next.map(\.id))
            for id in Array(tasks.keys) where !ids.contains(id) {
                let task = tasks.removeValue(forKey: id)
                task?.cancel()
                await task?.value
                previews.removeValue(forKey: id)
            }
            resources = next
            error = nil
            if previewsStarted { startPreviews() }
        } catch {
            self.error = "资源扫描失败：\(error.localizedDescription)"
        }
    }

    /// 一次为目录中每份候选建立库会话；搜索、离屏与进入详情都不争抢名额。
    func startPreviews() {
        previewsStarted = true
        for resource in resources where previews[resource.id] == nil {
            let session = DemoSession(preview: true)
            previews[resource.id] = session
            tasks[resource.id] = Task { await session.run(resource, loop: .infinite) }
        }
    }
}
