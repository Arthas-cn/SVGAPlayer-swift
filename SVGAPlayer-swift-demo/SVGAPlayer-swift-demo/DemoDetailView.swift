import SwiftUI
import UniformTypeIdentifiers
import SVGAPlayer_swift

/// 单资源验收页，只拥有一个会话；切换显示桥不会同时挂两个画面。
struct DemoDetailView: View {
    /// 原始候选，包括解析失败的文件。
    let resource: DemoResource
    /// 页面唯一播放会话，所有操作和报告复用它。
    @State private var session = DemoSession()
    /// 用户选择的显示边界，false 为库 SwiftUI 入口。
    @State private var native = false
    /// 进度拖动草稿，松手前不向库提交。
    @State private var progress = 0.0
    /// 正在拖动时不被诊断刷新覆盖草稿。
    @State private var dragging = false
    /// 显式循环选项，不用数字零作为库循环语义。
    @State private var repeatOption = DemoRepeatOption.once
    /// 当前画布适配选项。
    @State private var displayMode = SVGADisplayMode.aspectFit
    /// 自然结束后画面策略，与适配选项独立。
    @State private var endBehavior = SVGAEndBehavior.holdLastFrame
    /// 动态内容的真实目标 key，尚无目录时为空。
    @State private var selectedKey = ""
    /// 文本替换输入，仅内容改变时才提交栅格化。
    @State private var text = "SVGA · Swift"
    /// 文件选择器的显示状态。
    @State private var choosingImage = false

    /// 固定画布、播放控制、帧诊断、动态内容和只读诊断分别组织。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("画面") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("宿主", selection: $native) {
                            Text("SwiftUI").tag(false)
                            Text("UIKit / AppKit").tag(true)
                        }.pickerStyle(.segmented)
                        Group {
                            if native { DemoNativeView(player: session.player) }
                            else { SVGAView(player: session.player) }
                        }
                        .frame(height: 280)
                        .frame(maxWidth: .infinity)
                        .background(.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("detail.canvas")
                        Text(session.status).font(.headline)
                        Text(session.metadata).font(.caption).textSelection(.enabled)
                    }
                }
                playbackControls
                DemoPlaybackDebugControls(session: session)
                contentControls
                NavigationLink(value: DemoRoute.hosts(resource)) {
                    Label("SwiftUI / 原生宿主对照", systemImage: "rectangle.split.2x1")
                }.accessibilityIdentifier("detail.hostLab")
                DemoDiagnosticsView(session: session)
            }.padding()
        }
        .navigationTitle(resource.id)
        .task { await session.run(resource) }
        .onChange(of: native) { _, value in session.append("switchHost", parameters: value ? "native" : "SwiftUI") }
        .onChange(of: session.playback?.requestedPosition?.progress) { _, value in
            if !dragging { progress = value ?? 0 }
        }
        .onChange(of: session.keys) { _, keys in
            if !keys.contains(selectedKey) { selectedKey = keys.first ?? "" }
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                let key = selectedKey
                session.perform("replaceImage", key: key, parameters: "path=\(url.path)") { player in
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try await DemoImageInput.read(url)
                    try await player.replaceImage(with: data, forKey: key)
                }
            case .failure(let error): session.append("imageSelectionFailed", parameters: error.localizedDescription)
            }
        }
    }

    /// 基础播放和进度操作，滑杆只在松手时生成一次 seekProgress 事件。
    private var playbackControls: some View {
        GroupBox("播放控制") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("播放", systemImage: "play.fill") { session.perform("play") { try await $0.play() } }
                    Button("暂停", systemImage: "pause.fill") { session.perform("pause") { await $0.pause() } }
                    Button("从头播放") {
                        session.perform("restart") { try await $0.rewind(); try await $0.play() }
                    }
                }.disabled(!session.isLoaded)
                Slider(value: $progress, in: 0...1) { editing in
                    dragging = editing
                    if !editing {
                        let position = progress
                        session.perform("seekProgress", parameters: "progress=\(position)") { try await $0.seek(toProgress: position) }
                    }
                }.disabled(!session.isLoaded).accessibilityIdentifier("detail.progress")
                Picker("总轮数", selection: $repeatOption) {
                    ForEach(DemoRepeatOption.allCases) { Text($0.title).tag($0) }
                }.onChange(of: repeatOption) { _, value in
                    session.perform("changeLoop", parameters: value.title) { try await $0.changeLoop(to: value.loop) }
                }
                Picker("显示适配", selection: $displayMode) {
                    ForEach(SVGADisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.onChange(of: displayMode) { _, value in
                    session.perform("displayMode", parameters: value.rawValue) { await $0.changeDisplayMode(to: value) }
                }
                Picker("结束画面", selection: $endBehavior) {
                    Text("停在最后一帧").tag(SVGAEndBehavior.holdLastFrame)
                    Text("回到第一帧").tag(SVGAEndBehavior.returnToFirstFrame)
                    Text("清空").tag(SVGAEndBehavior.clear)
                }.onChange(of: endBehavior) { _, value in
                    session.perform("endBehavior", parameters: value.rawValue) { await $0.changeEndBehavior(to: value) }
                }
            }.buttonStyle(.bordered)
        }
    }

    /// 按文件真实 key 提供图片、文本和隐藏替换；无 key 时说明原因，不造占位槽位。
    private var contentControls: some View {
        GroupBox("动态内容") {
            VStack(alignment: .leading, spacing: 10) {
                if session.keys.isEmpty {
                    Text("该文件尚无可替换的真实精灵 key。解析失败时请查看下方诊断。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("精灵 key", selection: $selectedKey) {
                        ForEach(session.keys, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("替换文本", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading) {
                        Button("替换图片") { choosingImage = true }
                        Button("替换文本") {
                            let key = selectedKey, value = text
                            session.perform("replaceText", key: key, parameters: "text=\(value.prefix(2048))") {
                                try await $0.replaceText(with: SVGAText(value), forKey: key)
                            }
                        }
                        Button("隐藏") {
                            let key = selectedKey
                            session.perform("hide", key: key) { try await $0.hideSprite(forKey: key) }
                        }
                        Button("恢复源内容") {
                            let key = selectedKey
                            session.perform("restore", key: key) { try await $0.restoreSprite(forKey: key) }
                        }
                    }.disabled(!session.isLoaded || selectedKey.isEmpty)
                }
            }.buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("detail.contentControls")
    }
}

/// 详情 UI 的明确循环选项，最终传给库的仍是有限/无限枚举。
enum DemoRepeatOption: String, CaseIterable, Identifiable {
    /// 完整播放一次。
    case once
    /// 完整播放两次。
    case twice
    /// 无限播放，直到手动暂停。
    case forever
    /// 稳定 Picker 身份。
    var id: String { rawValue }
    /// 用户可读轮数。
    var title: String { switch self { case .once: "1 轮"; case .twice: "2 轮"; case .forever: "无限" } }
    /// 转换到库的显式循环语义。
    var loop: SVGALoop { switch self { case .once: .finite(1); case .twice: .finite(2); case .forever: .infinite } }
}

/// 只补充 demo 中文标签，不改变库枚举行为。
extension SVGADisplayMode {
    /// 四种画布适配的用户可读名称。
    var title: String {
        switch self { case .aspectFit: "完整显示"; case .aspectFill: "填满裁切"; case .stretch: "拉伸"; case .originalSize: "原始大小" }
    }
}

/// 用户选择的图片在后台读取，实际解码和替换仍由库负责。
nonisolated enum DemoImageInput {
    /// 读取前后响应取消，失败原样交给操作日志。
    @concurrent static func read(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        return data
    }
}
