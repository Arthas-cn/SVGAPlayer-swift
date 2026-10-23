#if os(iOS)
import UIKit
import QuartzCore

/// UIKit 薄宿主，只提供 Metal drawable；播放控制使用同一个 SVGAPlayer。
@MainActor public final class SVGAUIKitView: UIView {
    /// 绑定生命周期拥有者，初始化之前为 nil。
    private var binding: SurfaceBinding?
    /// 平台活动状态观察者；宿主销毁时移除，不让通知中心延长播放器寿命。
    private var lifecycleObservers: [any NSObjectProtocol] = []

    /// 使用单个 CAMetalLayer，不建立逐精灵图层树。
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    /// 将已有播放器挂到此宿主；不会新建或自动加载另一份影片。
    public init(player: SVGAPlayer) {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        guard let metal = layer as? CAMetalLayer else { return }
        binding = SurfaceBinding(player: player, layer: metal) { [weak self] in
            guard let self, window != nil, UIApplication.shared.applicationState == .active else { return false }
            var ancestor: UIView? = self
            while let view = ancestor {
                if view.isHidden || view.alpha == 0 { return false }
                ancestor = view.superview
            }
            return true
        }
        binding?.setRenderingEnabled(UIApplication.shared.applicationState == .active)
        observeApplicationActivity()
    }

    /// 移除 MainActor 上创建的观察者，已提交工作仍由播放器排空。
    isolated deinit {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// 失去活动状态时同步关闭提交，恢复时重绘；不改变调用方的播放、暂停或循环设置。
    private func observeApplicationActivity() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                // UIKit 生命周期通知在主线程同步发出；在通知返回前关门，不能另起 Task 延后处理。
                MainActor.assumeIsolated { self?.binding?.setRenderingEnabled(false) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.binding?.setRenderingEnabled(true) }
            }
        ]
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
