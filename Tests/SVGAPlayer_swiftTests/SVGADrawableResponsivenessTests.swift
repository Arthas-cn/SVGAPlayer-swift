import Foundation
import Metal
import QuartzCore
import Synchronization
import Testing
@testable import SVGAPlayer_swift

/// 显示缓冲耗尽时的线程与真实收尾回归；不依赖窗口、网络或 GPU 速度。
struct SVGADrawableResponsivenessTests {
    /// nextDrawable 尚未返回时主 actor 仍可执行；取消也必须等底层等待实际退出。
    @Test(arguments: [false, true]) @MainActor
    func drawableWaitKeepsMainActorResponsive(cancel: Bool) async throws {
        let layer = BlockingDrawableLayer()
        layer.drawableSize = CGSize(width: 16, height: 16)
        let surface = MetalSurface(layer: layer) { true }
        let context = try MetalContext.shared.get()
        let acquisition = Task { await surface.acquire(context: context) }
        var iterator = layer.probe.entered.stream.makeAsyncIterator()
        await iterator.next()
        // 只有主 actor 能在底层阻塞期间走到这里，才证明不是把同步等待藏进 async 签名。
        #expect(!layer.probe.hasReturned)
        #expect(!layer.probe.waitedOnMainThread)
        if cancel {
            // 取消只撤销使用意图，不能伪造系统 API 已结束。
            acquisition.cancel()
            #expect(!layer.probe.hasReturned)
        }
        layer.probe.release()
        #expect(await acquisition.value == nil)
        #expect(layer.probe.hasReturned)
    }
}

/// 用有界同步等待模拟池耗尽；两秒兜底只防止旧实现把整套测试永久锁死。
private final class DrawableWaitProbe: Sendable {
    /// 唯一消费者等待 API 已进入，而不是猜一个 sleep 时长。
    let entered = AsyncStream<Void>.makeStream()
    /// 测试拥有释放权；生产代码必须一直等到该信号后才返回。
    private let semaphore = DispatchSemaphore(value: 0)
    /// 跨线程观测实际返回及是否错误地在主线程等待。
    private let state = Mutex((returned: false, mainThread: false))

    /// 底层 API 是否已真实返回；不能用 Task 的取消状态代替。
    var hasReturned: Bool { state.withLock { $0.returned } }
    /// 进入同步 API 的线程是否是主线程。
    var waitedOnMainThread: Bool { state.withLock { $0.mainThread } }

    /// 先通知进入，再阻塞至业务放行；旧实现超时后也能输出明确断言失败。
    func wait() {
        state.withLock { $0.mainThread = Thread.isMainThread }
        entered.continuation.yield()
        _ = semaphore.wait(timeout: .now() + 2)
        state.withLock { $0.returned = true }
    }

    /// 只解除测试替身的同步等待，不取消真实异步收尾。
    func release() { semaphore.signal() }
}

/// 仅替换系统 drawable 获取，其他显示边界仍经过生产 MetalSurface。
private final class BlockingDrawableLayer: CAMetalLayer, @unchecked Sendable {
    /// 单个测试独占的等待控制，不保存播放器或窗口。
    let probe = DrawableWaitProbe()

    /// 模拟暂时没有 drawable；线程记录用于防止重新把阻塞移回主 actor。
    override func nextDrawable() -> (any CAMetalDrawable)? {
        probe.wait()
        return nil
    }
}
