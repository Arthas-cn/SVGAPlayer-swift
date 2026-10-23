import SwiftUI
import SVGAPlayer_swift

/// 显式进入后才创建两份独立会话，分别验收 SwiftUI 与当前平台原生宿主。
struct DemoHostLab: View {
    /// 两个会话共同加载的实际候选。
    let resource: DemoResource
    /// SwiftUI 边界的独立播放状态。
    @State private var first: DemoSession
    /// 原生边界的独立播放状态。
    @State private var second: DemoSession
    /// 两个显示目标是否挂入视图树。
    @State private var mounted = true
    /// 原生宿主祖先隐藏开关。
    @State private var hidden = false
    /// 支持零尺寸到普通画布高度的布局验收。
    @State private var height = 220.0

    /// 一次宿主对照共用 runID，分别导出带播放器身份的报告文件。
    init(resource: DemoResource) {
        self.resource = resource
        let runID = UUID()
        _first = State(initialValue: DemoSession(runID: runID))
        _second = State(initialValue: DemoSession(runID: runID))
    }

    /// 控制原生祖先和挂载状态，两个播放器的诊断始终分别展示。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("同一文件，两份独立播放会话").font(.headline)
                Toggle("挂载显示目标", isOn: $mounted)
                Toggle("隐藏原生祖先", isOn: $hidden)
                HStack { Text("画布高度 \(Int(height))"); Slider(value: $height, in: 0...420) }
                if mounted {
                    Text("SwiftUI · \(first.status)")
                    SVGAHostCanvas(session: first, native: false, hidden: false, height: height)
                    Text("UIKit / AppKit · \(second.status)")
                    SVGAHostCanvas(session: second, native: true, hidden: hidden, height: height)
                }
                DemoPlaybackDebugControls(session: first)
                DemoPlaybackDebugControls(session: second)
                DemoDiagnosticsView(session: first)
                DemoDiagnosticsView(session: second)
            }.padding()
        }
        .navigationTitle("宿主对照 · \(resource.id)")
        .accessibilityIdentifier("hostLab")
        .task { await first.run(resource, loop: .infinite) }
        .task { await second.run(resource, loop: .infinite) }
        .onChange(of: mounted) { _, value in log("mount", "mounted=\(value)") }
        .onChange(of: hidden) { _, value in second.append("ancestorHidden", parameters: "hidden=\(value)") }
        .onChange(of: height) { _, value in log("height", "height=\(value)") }
    }

    /// 两个边界使用相同复现参数，但操作记录保存在各自会话。
    private func log(_ operation: String, _ parameters: String) {
        first.append(operation, parameters: parameters)
        second.append(operation, parameters: parameters)
    }
}

/// 宿主对照的单一画布，实际显示能力仍完全来自库。
private struct SVGAHostCanvas: View {
    /// 当前画布对应的独立会话。
    let session: DemoSession
    /// 是否走 demo 的原生容器桥。
    let native: Bool
    /// 原生祖先隐藏状态。
    let hidden: Bool
    /// 当前画布逻辑高度。
    let height: Double
    /// 每个画布只有一个显示目标，零高度时仍保留会话诊断。
    var body: some View {
        Group {
            if native { DemoNativeView(player: session.player, ancestorHidden: hidden) }
            else { SVGAView(player: session.player) }
        }
        .frame(height: height)
        .background(.gray.opacity(0.15))
        .accessibilityIdentifier(native ? "hostLab.native.canvas" : "hostLab.swiftUI.canvas")
    }
}
