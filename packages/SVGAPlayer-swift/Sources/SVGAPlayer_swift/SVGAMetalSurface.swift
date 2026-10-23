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

    /// 绑定一个薄宿主的图层与可见性查询，不公开给库调用方。
    init(layer: CAMetalLayer, isVisible: @escaping @MainActor () -> Bool) {
        self.layer = layer
        self.isVisible = isVisible
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
    }

    /// 获取当前显示目标；平台停用、无窗口、隐藏或零尺寸返回 nil，由播放器记录不可用而不猜测呈现。
    func acquire(context: MetalContext) -> SurfaceFrame? {
        guard submissionGate.isEnabled, isVisible(),
              layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return nil }
        if layer.device == nil { layer.device = context.device }
        guard let drawable = layer.nextDrawable() else { return nil }
        return SurfaceFrame(drawable: drawable, scale: layer.contentsScale, submissionGate: submissionGate)
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
