# SVGAPlayer-swift

Swift 6.4 / iOS 26 / macOS 26 的 SVGA 重写。库为 SPM product `SVGAPlayer-swift`，导入名 `SVGAPlayer_swift`。库默认 `nonisolated`，播放状态由独立 actor 管理；SwiftUI、UIKit、AppKit 只承载一个 `CAMetalLayer`。

完整功能、参数、详情页操作和排错方法见 [使用说明](使用说明.md)。

## 目录与数据流

- `packages/SVGAPlayer-swift`：影片、解析缓存、播放控制、Metal 合成与平台宿主。
- `packages/SVGAPlayer-swift/Schema`：官方 protobuf schema 与固定版本出处；生成类型为 internal。
- `packages/SVGAPlayer-swift/Tests`：Swift Testing，夹具均来自真实 `.svga`，损坏测试明确使用截断或无效输入。
- `SVGAPlayer-swift-demo`：现有 Xcode 工程，链接相对路径本地包；`resoureces` 保持原拼写和 133 份源文件。

文件 → 分块读取与 SHA-256 → ZIP/zlib → SwiftProtobuf 或 1.x JSON → 不可变 `SVGAMovie` → 后台图片/几何/音频准备 → `SVGAPlayer` 时间轴 → Metal drawable。

`SVGALoader` 共享相同内容的解析，在途等待者可以分别取消。缓存失效不会让旧完成重新填回缓存。每个安装只解码、上传一次位图；矢量填充和描边预先缓存成几何。普通播放直接写 drawable；clip、matte 及连续 matte 组只使用 GPU 附件，不读回 CPU、不使用逐精灵 CALayer。

## 使用

```swift
import SVGAPlayer_swift

let player = SVGAPlayer()
let result = try await SVGALoader.shared.load(from: fileURL)
try await player.install(result.movie) // 准备第一帧，不自动播放
try await player.changeLoop(to: .finite(2))
try await player.play()
```

MainActor 的 SwiftUI 页面使用 `SVGAView(player: player)`；原生页面使用 `SVGAUIKitView(player:)` 或 `SVGAAppKitView(player:)`。同一播放器只有一个当前显示目标，两个并列画面应使用两个播放器。宿主之间切换不重新创建播放会话。页面退出时 `await player.shutdown()` 等待准备、替换与 GPU 工作排空。

- `seek(toFrame:)` 接受整数源帧，`seek(toProgress:)` 接受有限的 `0...1`。越界抛错。
- `changeDisplayMode(to:)`：`.aspectFit`、`.aspectFill`、`.stretch`、`.originalSize`。
- `changeEndBehavior(to:)`：`.holdLastFrame`、`.returnToFirstFrame`、`.clear`。
- `replaceImage(with:forKey:)` 接受图片编码 `Data`，`replaceText(with:forKey:)` 接受 `SVGAText`。
- `hideSprite(forKey:)`、`restoreSprite(forKey:)` 使用 `movie.spriteKeys` 中的真实 key。同名 key 的所有实例一起变更。替换纹理覆盖源位图与矢量，恢复时回到源内容。
- 替换失败仅生成内容事件并抛错，不把整次播放标为失败。后来的同 key 意图、seek、安装和宿主切换都会使旧帧/旧替换结果失效。

## Demo 复现

用 Xcode 打开 `SVGAPlayer-swift-demo/SVGAPlayer-swift-demo.xcodeproj`，scheme 为 `SVGAPlayer-swift-demo`，运行 macOS 或 iOS 模拟器。

启动参数只消费一次：

```text
--svga-sample=12.svga
--svga-sample=65.svga --svga-host-lab
--svga-batch
```

列表从 bundle 扫描；搜索只改变显示，不缩小批播计划。所有行都有持久播放会话，无可见行配额；离屏宿主不存在时不会伪造 GPU 完成，也不卸掉行会话。详情只有一个会话；宿主对照页才创建两个。详情首次 GPU 完成预算为 15 秒，包含读取和准备；批播单份上限为 `max(20, duration * 2 + 10)` 秒。

诊断约 250ms 更新。帧事件最多 128 条，宿主操作最多 128 条，内容事件最多 256 条；控制台过滤和冻结只影响显示。报告在显式导出、单份完成或批次结束时异步保存到本 app 的 `Caches/SVGASwiftReports/<runID>/`，最多十个 run。界面显示真实成功路径和导出错误，并提供分享。

报告阶段含义：

- `parsing`：本次加载成功、失败、取消或未执行；失败也携带自己的 `SVGALoadReport`。
- `rendering`：只有真实 GPU 完成计数大于零才为 `completed`。
- `playback`：自然完成且确实经过完整一轮才为 `finished`；预览、首帧、手动暂停、seek 跳过不能冒充完整播放。
- `visual`：默认 `pending`，批播不会自动宣称画面正确。

JSON 的可选阶段字段缺失表示 `nil` / 尚未观测，不应解释成零。系统呈现取自 drawable 回调，与 GPU 完成分开；当前 iOS Simulator SDK 不提供该回调，模拟器系统呈现字段保持 `nil`。缓存计费和 GPU 输入留存均不是进程 RSS。

稳定可访问性身份包括 `catalog.item.<文件名>`、`catalog.playAll`、`detail.canvas`、`detail.progress`、`detail.debugControls`、`detail.contentControls`、`detail.diagnostics`、`batch.canvas`、`batch.item.<文件名>`、`hostLab.swiftUI.canvas`、`hostLab.native.canvas`。

## 验证

```sh
swift package --package-path packages/SVGAPlayer-swift dump-package
swift test --package-path packages/SVGAPlayer-swift
xcodebuild -project SVGAPlayer-swift-demo/SVGAPlayer-swift-demo.xcodeproj \
  -scheme SVGAPlayer-swift-demo -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SVGAPlayer-swift-demo/SVGAPlayer-swift-demo.xcodeproj \
  -scheme SVGAPlayer-swift-demo -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

2026-10-23 验证记录见 `docs/verification.md`。库测试不依赖旧 Objective-C 库。完整目录测试定位仓库里的真实 `resoureces`；单独复制 SPM 包时该项按测试说明跳过，包内夹具测试仍运行。

建议交互回归：拖动进度后确认仅松手产生 seek；暂停后前后逐帧；切换宿主时核对 playerID 不变；输入真实 key 替换/隐藏/恢复；连续重载后清空；宿主隐藏、卸载、零高度再恢复；批播取消后核对未运行计划项仍保留。所有这些操作都可从 JSON 操作参数、安装身份、内容事件和帧阶段追踪。

## 证据与边界

- 容器分流、载荷优先级与图片附件：旧库 `Source/SVGAParser.m`、`SVGAVideoEntity.m`。
- 布局、矩阵、clip：`SVGAVideoSpriteFrameEntity.m`、`SVGAContentLayer.stepToFrame:`。
- keep、填充、描边与 dash：`SVGAVectorLayer` 的 `isKeepFrame` / `resetStyles` / `resetTransform`。
- matte 连续分组与源画布裁切：`SVGAPlayer.draw`；音频按 `SVGAPlayer.stepToFrame` 的起止帧对齐。
- protobuf 使用官方 SwiftProtobuf 1.39.0，通过 SPM 固定依赖；官方 schema 来源及生成步骤见 `Schema/SOURCE.txt`。

ZIP 支持单卷 stored/DEFLATE、中央目录、data descriptor 与 CRC；ZIP64、加密、多卷明确失败。SVG 路径支持旧实现有证据的 `M/L/H/V/C/Q/Z` 及其小写形式，其余命令明确失败。输入/解压上限 256 MiB，单项栅格化上限 16,777,216 像素，单影片 GPU 输入上限 512 MiB，局部 GPU 遮罩附件上限 256 MiB；超限返回错误，不静默降画质。

当前矢量为单采样 winding stencil，未实现 MSAA。尚未对 133 份文件的每一帧与旧库做逐像素比对，也没有真机音频听感和 GPU 性能对照结论。整段图片导出不属于播放路径，本次未提供。引用仓库均只读，终态没有 ProtobufObjC、SSZipArchive、CocoaPods 或旧播放器依赖。
