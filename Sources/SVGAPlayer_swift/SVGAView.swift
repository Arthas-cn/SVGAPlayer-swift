import SwiftUI

/// SwiftUI 显示入口，复用原生薄宿主与调用者提供的唯一播放会话。
@MainActor public struct SVGAView: View {
    /// 外部拥有的播放会话；此 View 不读取文件、不另起时钟。
    private let player: SVGAPlayer

    /// 创建显示边界；播放器可在 SwiftUI 与原生宿主间切换。
    public init(player: SVGAPlayer) { self.player = player }

    /// 平台适配仅负责挂载与布局。
    public var body: some View { PlatformSVGAView(player: player).id(player.id) }
}

#if os(iOS)
/// UIKit 的 SwiftUI 桥，不复制播放状态或内容目录。
private struct PlatformSVGAView: UIViewRepresentable {
    /// 调用者提供的会话。
    let player: SVGAPlayer
    /// 创建唯一薄宿主。
    func makeUIView(context: Context) -> SVGAUIKitView { SVGAUIKitView(player: player) }
    /// 控制通过 player API 完成；SwiftUI 值更新本身不重载影片。
    func updateUIView(_ view: SVGAUIKitView, context: Context) {}
}
#elseif os(macOS)
/// AppKit 的 SwiftUI 桥，不复制播放状态或内容目录。
private struct PlatformSVGAView: NSViewRepresentable {
    /// 调用者提供的会话。
    let player: SVGAPlayer
    /// 创建唯一薄宿主。
    func makeNSView(context: Context) -> SVGAAppKitView { SVGAAppKitView(player: player) }
    /// 播放命令只由外部会话发出，视图刷新不隐式重载。
    func updateNSView(_ view: SVGAAppKitView, context: Context) {}
}
#endif
