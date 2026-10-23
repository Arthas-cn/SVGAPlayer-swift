import SwiftUI
import SVGAPlayer_swift
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
/// 验收用原生桥；额外祖先只用于测试隐藏，真正显示仍使用库 AppKit 宿主。
struct DemoNativeView: NSViewRepresentable {
    /// 页面提供的唯一播放会话。
    let player: SVGAPlayer
    /// 控制宿主的原生祖先隐藏，而非只改 SwiftUI opacity。
    var ancestorHidden = false
    /// 创建祖先容器并挂载库宿主，不编写任何合成代码。
    func makeNSView(context: Context) -> NSView {
        let root = NSView()
        let host = SVGAAppKitView(player: player)
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor), host.topAnchor.constraint(equalTo: root.topAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        return root
    }
    /// 原生隐藏变化后通知子宿主布局，恢复时可重绘暂停帧。
    func updateNSView(_ view: NSView, context: Context) {
        view.isHidden = ancestorHidden
        view.subviews.first?.needsLayout = true
    }
}
#else
/// UIKit 原生对照桥；祖先控制只用于生命周期验收。
struct DemoNativeView: UIViewRepresentable {
    /// 页面提供的唯一播放会话。
    let player: SVGAPlayer
    /// 原生祖先是否隐藏。
    var ancestorHidden = false
    /// 创建容器并以约束铺满库宿主。
    func makeUIView(context: Context) -> UIView {
        let root = UIView()
        let host = SVGAUIKitView(player: player)
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor), host.topAnchor.constraint(equalTo: root.topAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        return root
    }
    /// 更新原生祖先隐藏并触发暂停帧的重绘机会。
    func updateUIView(_ view: UIView, context: Context) {
        view.isHidden = ancestorHidden
        view.subviews.first?.setNeedsLayout()
    }
}
#endif
