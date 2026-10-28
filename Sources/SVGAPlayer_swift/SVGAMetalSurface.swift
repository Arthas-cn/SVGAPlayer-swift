import Foundation
import QuartzCore
import Metal

/// 仅在 MainActor 访问的显示边界；不推进时间轴、不合成精灵。
@MainActor final class MetalSurface {
    /// 挂在原生宿主上的唯一 CAMetalLayer。
    let layer: CAMetalLayer
    /// 宿主实际挂载/祖先隐藏状态，不根据滚动可见名额限制播放器。
    let isVisible: @MainActor () -> Bool
    /// 可跨 actor 同步检查的平台提交许可，获取与提交之间的后台切换也受保护。
    let submissionGate = MetalSubmissionGate()
    /// 每个宿主独占的 drawable 等待队列；阻塞系统调用不能占住主 actor。
    private let drawables: MetalDrawableAcquisition

    /// 绑定一个薄宿主的图层与可见性查询，不公开给库调用方。
    init(layer: CAMetalLayer, isVisible: @escaping @MainActor () -> Bool) {
        self.layer = layer
        self.isVisible = isVisible
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        drawables = MetalDrawableAcquisition(layer: layer)
    }

    /// 在主 actor 核验宿主，再异步等待显示目标；取消不会提前结束尚在运行的系统调用。
    /// 平台停用、无窗口、隐藏或零尺寸返回 nil，由播放器记录不可用而不猜测呈现。
    func acquire(context: MetalContext) async -> SurfaceFrame? {
        guard submissionGate.isEnabled, isVisible(),
              layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return nil }
        if layer.device == nil { layer.device = context.device }
        // nextDrawable 在缓冲耗尽时可能等一秒；多个播放器串在主线程等待会让整屏失去响应。
        // scale 是本次布局快照；等待期间的新布局、换片和解绑由播放器 revision 再次核验。
        return await drawables.acquire(scale: layer.contentsScale, gate: submissionGate)
    }
}

/// 只跨线程获取 drawable，不访问 UIView/NSView 或修改层树；每个播放器最多有一次获取在途。
/// unchecked 仅覆盖 CAMetalLayer 的系统线程安全获取入口，属性与层树仍归主 actor。
private final class MetalDrawableAcquisition: @unchecked Sendable {
    /// 保持显示层存活至系统调用真正结束；不把借出的 drawable 留存在此对象中。
    private let layer: CAMetalLayer
    /// 阻塞工作使用 Dispatch 线程，不阻塞主线程或 Swift cooperative executor。
    private let queue = DispatchQueue(label: "svga.drawable", qos: .userInteractive)

    /// 在主 actor 完成显示层配置后建立唯一后台获取边界。
    @MainActor init(layer: CAMetalLayer) { self.layer = layer }

    /// 真实调用退出后才恢复调用方；前后台切换后取得的目标直接丢弃。
    func acquire(scale: Double, gate: MetalSubmissionGate) async -> SurfaceFrame? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let frame: SurfaceFrame? = autoreleasepool {
                    // 队列排队与系统等待都允许生命周期变化，前后两次核验不能合并。
                    guard gate.isEnabled, let drawable = layer.nextDrawable(), gate.isEnabled else { return nil }
                    return SurfaceFrame(drawable: drawable, scale: scale, submissionGate: gate)
                }
                // 不用取消处理器提前 resume：shutdown 必须等 drawable 的实际所有权交还。
                continuation.resume(returning: frame)
            }
        }
    }
}

/// drawable 的一次提交拥有权；工作线程可编码，实际提交受平台许可保护，图层仍只在 MainActor 访问。
struct SurfaceFrame: @unchecked Sendable {
    /// 仅由拿到此值的一次帧请求提交，不能重复 present。
    let drawable: any CAMetalDrawable
    /// 目标像素与逻辑点比例，供原始大小适配使用。
    let scale: Double
    /// 提交前再次原子核验；取得 drawable 不代表此时仍获准使用 GPU。
    let submissionGate: MetalSubmissionGate
}

/// 平台宿主的最小绑定控制，所有异步通知按宿主身份校验。
@MainActor final class SurfaceBinding {
    /// 当前宿主独立身份，切换代表对象时不会复用。
    let id = UUID()
    /// 保持同一个播放会话，SwiftUI 和原生宿主可先后绑定它。
    let player: SVGAPlayer
    /// MainActor 显示边界。
    let surface: MetalSurface
    /// 初始挂载任务，布局更新必须在绑定完成后通知。
    private var attachment: Task<Void, Never>?

    /// 创建薄边界并异步挂载到播放器。
    init(player: SVGAPlayer, layer: CAMetalLayer, isVisible: @escaping @MainActor () -> Bool) {
        self.player = player
        surface = MetalSurface(layer: layer, isVisible: isVisible)
        let id = id, surface = surface
        attachment = Task { await player.attach(surface, id: id) }
    }

    /// 等待初始化已创建的挂载任务；取消调用方也不能跳过真实绑定收口。
    func waitUntilAttached() async { await attachment?.value }

    /// 销毁时只解绑自己的身份，不取消仍在其他宿主中使用的播放器。
    isolated deinit {
        let player = player, id = id, pending = attachment
        Task {
            await pending?.value
            await player.detach(id: id)
        }
    }

    /// 更新物理像素尺寸并请求重绘；几何和播放求值不进入平台 View。
    func update(size: CGSize, scale: Double) {
        surface.layer.contentsScale = scale
        surface.layer.drawableSize = CGSize(width: max(0, size.width * scale), height: max(0, size.height * scale))
        let player = player, id = id, pending = attachment
        Task {
            await pending?.value
            await player.surfaceChanged(id: id)
        }
    }

    /// 平台停用先关提交许可并等待已提交工作被调度；恢复时主动请求暂停帧或最新帧重绘。
    func setRenderingEnabled(_ enabled: Bool) {
        surface.submissionGate.setEnabled(enabled)
        guard enabled else { return }
        let player = player, id = id, pending = attachment
        Task {
            await pending?.value
            await player.surfaceChanged(id: id)
        }
    }
}
