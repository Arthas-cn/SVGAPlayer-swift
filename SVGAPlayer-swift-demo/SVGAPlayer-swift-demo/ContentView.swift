import SwiftUI
import SVGAPlayer_swift

/// 资源目录与导航入口；行预览全部使用库 SVGAView，不在 App 内实现播放器。
struct ContentView: View {
    /// 稳定目录与每行会话拥有者。
    @State private var catalog = DemoCatalogModel()
    /// 导航路径，列表返回时不重复应用启动参数。
    @State private var path: [DemoRoute] = []
    /// 启动参数的单次消费标记。
    @State private var appliedArguments = false
    /// 指定文件不存在时显示真实错误。
    @State private var launchError: String?

    /// 搜索只改变列表；批播始终接收完整目录。
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let error = catalog.error ?? launchError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    ForEach(catalog.filtered) { resource in
                        NavigationLink(value: DemoRoute.detail(resource)) {
                            DemoResourceRow(resource: resource, session: catalog.previews[resource.id])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("catalog.item.\(resource.id)")
                    }
                    if catalog.filtered.isEmpty && !catalog.isScanning && catalog.error == nil {
                        ContentUnavailableView("没有匹配资源", systemImage: "film",
                                               description: Text("从 Bundle 的 resoureces 扫描 .svga 文件。"))
                    }
                }
                .padding()
            }
            .navigationTitle("SVGA · \(catalog.filtered.count) / \(catalog.resources.count)")
            .searchable(text: $catalog.query, prompt: "搜索文件名")
            .toolbar {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await catalog.refresh() } }
                    .disabled(catalog.isScanning).accessibilityIdentifier("catalog.refresh")
                NavigationLink(value: DemoRoute.batch) { Label("播放全部", systemImage: "play.rectangle.on.rectangle") }
                    .disabled(catalog.resources.isEmpty).accessibilityIdentifier("catalog.playAll")
            }
            .refreshable { await catalog.refresh() }
            .navigationDestination(for: DemoRoute.self) { route in
                switch route {
                case .detail(let resource): DemoDetailView(resource: resource)
                case .hosts(let resource): DemoHostLab(resource: resource)
                case .batch: DemoBatchView(resources: catalog.resources)
                }
            }
        }
        .frame(minWidth: 340)
        .task {
            await catalog.refresh()
            guard !appliedArguments else { return }
            appliedArguments = true
            if CommandLine.arguments.contains("--svga-batch") { path = [.batch] }
            else if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--svga-sample=") }) {
                let name = String(argument.dropFirst("--svga-sample=".count))
                if let resource = catalog.resources.first(where: { $0.id == name }) {
                    path = [CommandLine.arguments.contains("--svga-host-lab") ? .hosts(resource) : .detail(resource)]
                } else { launchError = "启动参数中的样本不存在：\(name)" }
            }
            if path.isEmpty { catalog.startPreviews() }
        }
        .onChange(of: path) { _, next in if next.isEmpty { catalog.startPreviews() } }
    }
}

/// 一行真实资源摘要，解析失败仍保留可点击详情和原始文件身份。
private struct DemoResourceRow: View {
    /// 扫描得到的文件元数据。
    let resource: DemoResource
    /// 目录拥有的长期预览会话，创建前为 nil。
    let session: DemoSession?

    /// 无名额等待逻辑，预览尺寸固定且播放器不随滚动销毁。
    var body: some View {
        HStack(spacing: 14) {
            if let session {
                SVGAView(player: session.player)
                    .frame(width: 112, height: 112)
                    .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(resource.id).font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(resource.byteCount), countStyle: .file))
                Text(session?.metadata ?? "尚未加载")
                Text(session?.status ?? "准备预览")
                    .foregroundStyle(session?.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(3)
            }
            .font(.caption)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }
}
