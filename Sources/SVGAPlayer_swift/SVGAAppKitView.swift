#if os(macOS)
import AppKit
import QuartzCore

/// AppKit 薄宿主，只挂一个 Metal 显示目标；编码和时间轴都属于 SVGAPlayer。
@MainActor public final class SVGAAppKitView: NSView {
    /// 宿主生命周期绑定，初始化之前为 nil。
    private var binding: SurfaceBinding?

    /// 挂载已有会话，不创建第二套播放状态。
    public init(player: SVGAPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        guard let metal = layer as? CAMetalLayer else { return }
        binding = SurfaceBinding(player: player, layer: metal) { [weak self] in
            guard let self else { return false }
            return window?.isVisible == true && !isHiddenOrHasHiddenAncestor
        }
    }

    /// 不允许归档隐式创建会话，使用显式 player 初始化器。
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("请使用 init(player:)") }

    /// AppKit backing layer 只使用 CAMetalLayer，不创建精灵子层。
    public override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    /// 与影片和 SwiftUI 一致使用左上坐标原点。
    public override var isFlipped: Bool { true }

    /// 只根据宿主 bounds 与屏幕比例更新目标像素数。
    public override func layout() {
        super.layout()
        binding?.update(size: bounds.size, scale: Double(window?.backingScaleFactor ?? 1))
    }

    /// 窗口绑定变化后触发首帧或暂停帧重绘。
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// 跨屏幕比例变化不重建播放器，只更新显示目标。
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// 自身隐藏变化请求布局；祖先隐藏状态仍在每次 acquire 时核验。
    public override var isHidden: Bool {
        didSet { needsLayout = true }
    }
}
#endif
