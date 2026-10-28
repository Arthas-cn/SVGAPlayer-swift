import Foundation
import Metal
import Synchronization

/// 同步协调显示提交和平台活动状态；时间轴仍归播放器 actor，不把库改成 MainActor 隔离。
final class MetalSubmissionGate: Sendable {
    /// 许可检查、提交与在途登记共享同一把锁，防止取到 drawable 后才进入后台的竞态。
    private let storage = Mutex(SubmissionState())

    /// 当前是否允许获取 drawable 和提交；读取不等待 GPU 工作结束。
    var isEnabled: Bool { storage.withLock { $0.isEnabled } }

    /// 关闭时先阻止新提交，再等已有提交被系统调度；只在平台生命周期切换时等待。
    /// 依据 Apple Preparing your Metal app to run in the background，不等待整帧 GPU 完成。
    func setEnabled(_ enabled: Bool) {
        let pending = storage.withLock { state -> [any MTLCommandBuffer] in
            state.isEnabled = enabled
            return enabled ? [] : Array(state.inFlight.values)
        }
        // 等待期间不能持锁：完成回调也要移除在途身份，否则会互相阻塞。
        for command in pending { command.waitUntilScheduled() }
    }

    /// 只在仍获许可时登记、present 并 commit 一次；返回 false 时命令保持未提交，由调用方记跳过。
    func submit(_ command: any MTLCommandBuffer, present: () -> Void) -> Bool {
        storage.withLock { state in
            guard state.isEnabled else { return false }
            let id = ObjectIdentifier(command)
            state.inFlight[id] = command
            command.addCompletedHandler { [weak self] _ in self?.finish(id) }
            // present 和 commit 必须与许可检查在同一临界区；关闭通知返回后不能再插入旧提交。
            present()
            command.commit()
            return true
        }
    }

    /// 命令终结后立即释放登记的资源引用，避免暂停或清空后仍被宿主留存。
    private func finish(_ id: ObjectIdentifier) {
        _ = storage.withLock { $0.inFlight.removeValue(forKey: id) }
    }
}

/// 只在提交锁内读写的 SDK 资源登记；unchecked 仅覆盖 MTLCommandBuffer 未标注 Sendable 的引用。
private struct SubmissionState: @unchecked Sendable {
    /// macOS 与普通宿主默认可提交；UIKit 初始化时会根据真实活动状态立即覆盖。
    var isEnabled = true
    /// 已实际提交而尚未完成的命令，停用时等待其调度，完成时释放。
    var inFlight: [ObjectIdentifier: any MTLCommandBuffer] = [:]
}
