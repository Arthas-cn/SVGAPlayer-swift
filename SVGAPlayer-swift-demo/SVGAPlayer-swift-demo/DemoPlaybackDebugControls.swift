import SwiftUI
import SVGAPlayer_swift

/// 帧级诊断命令矩阵，只调用当前详情唯一播放器。
struct DemoPlaybackDebugControls: View {
    /// 页面会话与日志拥有者。
    let session: DemoSession

    /// 清空后仍能重新准备，重载入口不能跟随播放状态一起禁用。
    var body: some View {
        GroupBox("帧级诊断") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading) {
                    Button("上一帧") { session.step(-1) }
                    Button("下一帧") { session.step(1) }
                    Button("回到开头并暂停") { session.perform("rewind") { try await $0.rewind() } }
                    Button("重绘当前帧") { session.perform("redraw") { await $0.redraw() } }
                }.disabled(!session.isLoaded)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading) {
                    Button("只准备不播放") { session.reload(autoplay: false) }
                    Button("走缓存重载") { session.reload() }
                    Button("强制重新解析") { session.reload(policy: .reload) }
                }
                Button("清空并取消未完成替换") { session.perform("clear") { _ in await session.clear() } }
                Text("逐帧操作记录整数 frame；进度滑杆单独记录 0…1 progress。GPU 完成和系统呈现见下方诊断。")
                    .font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("detail.debugControls")
    }
}
