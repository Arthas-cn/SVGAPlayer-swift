#if os(iOS)
import UIKit
import QuartzCore

/// UIKit 薄宿主，只提供 Metal drawable；播放控制使用同一个 SVGAPlayer。
@MainActor public final class SVGAUIKitView: UIView {
    /// 绑定生命周期拥有者，初始化之前为 nil。
    private var binding: SurfaceBinding?

    /// 使用单个 CAMetalLayer，不建立逐精灵图层树。
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    /// 将已有播放器挂到此宿主；不会新建或自动加载另一份影片。
    public init(player: SVGAPlayer) {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        guard let metal = layer as? CAMetalLayer else { return }
        binding = SurfaceBinding(player: player, layer: metal) { [weak self] in
            guard let self, window != nil else { return false }
            var ancestor: UIView? = self
            while let view = ancestor {
                if view.isHidden || view.alpha == 0 { return false }
                ancestor = view.superview
            }
            return true
        }
    }

    /// 不支持 NSCoder 隐式创建播放会话；调用者必须显式传入播放器。
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用 init(player:)") }

    /// 布局只更新 drawable 尺寸，不修改源影片或时间轴。
    public override func layoutSubviews() {
        super.layoutSubviews()
        binding?.update(size: bounds.size, scale: Double(window?.screen.scale ?? traitCollection.displayScale))
    }

    /// 挂载与重新挂载时主动重绘暂停帧。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    /// 自身隐藏状态变化后也通知播放器；祖先状态在每次 acquire 时再次验证。
    public override var isHidden: Bool {
        didSet { setNeedsLayout() }
    }
}
#endif
