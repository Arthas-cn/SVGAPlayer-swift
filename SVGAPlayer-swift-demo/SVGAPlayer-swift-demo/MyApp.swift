import SwiftUI

/// 双平台 demo 入口；macOS 固定一个窗口，避免复制多套验收会话。
@main struct MyApp: App {
    /// 承载资源目录与详情导航；iOS 保留系统场景生命周期。
    var body: some Scene {
        #if os(macOS)
        Window("SVGA 资源库", id: "main") {
            ContentView()
        }
        .defaultSize(width: 900, height: 960)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}
