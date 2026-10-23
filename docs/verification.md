# 2026-10-23 验证记录

## 自动验证

- `swift package dump-package` 成功：iOS/macOS 26、Swift 6 语言模式、库默认 nonisolated、Approachable Concurrency、SwiftProtobuf 1.39.0。
- `swift test`：20 个用例、5 组全部通过。包括 133 份真实样本解析与矢量准备、ZIP protobuf / ZIP JSON / zlib、音频元数据、损坏输入、独立取消、共享等待、缓存失效和旧结果丢弃、时间轴完整轮数、内容失败隔离、Metal 命令完成、过期 GPU 与系统呈现回调、事件上限、文本纹理方向和预先取消安装的状态收尾。
- macOS Debug 和 iOS Simulator Debug 的 `xcodebuild` 均成功，App target 真正链接本地 SPM product；bundle 内有完整 `resoureces`。
- 工程 `plutil -lint` 与 `git diff --check` 通过。手写 Swift 最大文件低于 550 行；官方生成的 `svga.pb.swift` 不计入手写体量。声明使用中文 `///`，取消、失效、遮罩与其他关键分支有 `//`，每个测试用例均说明场景。

首次抓取官方 SwiftProtobuf 历史较慢，本机验证使用 `/tmp/svga-official-cache` 的官方 tag 1.39.0 git 缓存，命令额外传入 `--cache-path` / `-packageCachePath`。仓库清单和 lockfile 仍引用官方 URL，没有本机 mirror 或第三方二进制依赖。

## 完整批播

实测 runID：`05BED69D-5222-4A2E-8104-35459D887E1E`。

原始报告：`~/Library/Caches/SVGASwiftReports/05BED69D-5222-4A2E-8104-35459D887E1E/batch.json`。它仍受 demo 的十个 run 保留策略管理；仓库另保存 [紧凑证据](verification/batch-summary.json)，包含原报告 SHA-256 和逐份 GPU / 呈现 / 完整轮数。

- 计划顺序为 `1.svga` 至 `133.svga`，全部尝试。
- 只有一个 playerID，133 个不同安装身份。
- 133 份均有 GPU 完成，并自然经过完整一轮；失败 0，取消 false。
- 126 份报告观测到有效系统呈现；`127.svga` 至 `133.svga` 的呈现回调为零时间，只记录了 `zeroTimeSkips`。它们的 GPU 完成不能作为系统已显示的证据，未把缺失值补成计数。
- 四类报告字段保持独立；所有批播 `visual` 均为 `pending`。
- 此批次在 `relativePath` 显式编码补充之前执行；之后的最终详情报告已核对 `resource.relativePath`、完整 URL、阶段状态和真实呈现字段。

## 已查看的真实画面

以下图片由本次 iPhone 18 Pro / iOS 27 模拟器运行捕获，不是设计稿或离屏合成产物：

- [默认目录](verification/catalog.png)：标题 `133 / 133`，多个行预览在播放，文件大小和解析摘要可见；未实现可见行名额。
- [12.svga 详情](verification/12.png)：角色方向、透明背景、画布适配与自然结束后的保留帧已查看。
- [65.svga 双宿主](verification/hosts-65.png)：包含实际矢量填充的样本，SwiftUI 与 UIKit 两份独立会话均显示角色与矢量泪水。
- [133.svga 双宿主](verification/hosts-133.png)：两份独立会话均显示位图手柄内容。

这些观察不代表 133 份每一帧均与旧库一致。未改写批播中的人工画面状态。原生电脑界面检查工具连接失败，因此界面截图通过 Xcode 的模拟器调试工具取得；尚未自动逐个点击验证全部控件、隐藏祖先、零尺寸、分享面板和导航返回路径。

## 留给真机与视觉验收的项目

- 在真实 iOS/macOS 设备上对照原播放器检查音频听感、首帧与连续播放性能；当前没有宣称性能提升百分比。
- 用遮罩、细描边和大幅缩放样本做逐帧画面对照；当前单采样 stencil 未实现 MSAA。
- 按 README 的交互清单验证连续替换、宿主挂卸、隐藏与恢复、批次取消和分享。库层的取消、迟到完成和内容失败路径已有自动回归，但不能替代这些 UI 操作。

未提交 git、未推远程；两个参考仓库保持只读。

## 后续真机回归：后台 Metal 权限拒绝

设备为 iPhone 15，iOS 26.2。用户报告列表前几行报 Metal 错误，已从 [现场截图](verification/device-metal-error-before.png) 确认 `MTLCommandBufferErrorDomain Code=7`。单播放器顺序批播可以完成全部 133 份，因此不能用批播通过排除列表的生命周期问题。

旧宿主只检查窗口、隐藏和尺寸，没有检查 App 活动状态；取到 drawable 后也没有在实际提交前核验后台切换。驱动拒绝在途工作后，旧代码把权限错误升级为永久 `.failed`。错误码依据本机 SDK `MTLCommandBuffer.h` 的 `MTLCommandBufferErrorNotPermitted = 7`；平台要求见 [Apple 后台 Metal 指南](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background)。

修复包括：

- UIKit 在失去活动状态时同步停止新 GPU 提交，等待已提交命令被系统调度；恢复后主动重绘。
- 获取 drawable 与实际 present / commit 共用线程安全提交许可，覆盖两者之间发生生命周期切换的竞态。
- 仅将 Metal `notPermitted` 记为可恢复的 `gpuUnavailable` 事件和 `gpuUnavailableSkips`，不增加 GPU 完成计数；其他 Metal 错误继续作为主失败。
- 不改变调用方的播放、暂停或循环设置，也不增加列表预览名额限制。

新增 6 个回归用例，总计 **26 个测试、6 组通过**。覆盖错误域分类、Code=7 后可恢复、严重 GPU 错误仍失败、停用后不 present / commit、等待已提交命令调度，以及前台恢复重绘暂停帧。macOS、iOS Simulator 和使用现有签名的真机构建均成功。

修复版已安装到同一真机，在同一进程连续进行三次前后台切换。第 1、3 次及延后检查的实际列表画面中，前四行均保持 `playing`，角色姿态发生变化；[恢复后的截图](verification/device-metal-error-after.png) 已保存。第 2 次截图处于系统任务切换过渡，不作为最终画面通过证据。

根目录 [使用说明](../使用说明.md) 已覆盖全部公开功能和详情页操作。文档中的 Swift 示例分别针对 macOS 与 iOS 做了类型检查，文内链接和公开声明名称覆盖检查通过。

修复版同一真机的完整批播也已结束，runID 为 `48052D8B-34E2-49EB-80EC-437E13141FFF`：计划 133、尝试 133、自然完整一轮 133、失败 0、未取消，整个批次只有一个 playerID，全部有成功 GPU 完成。可查看 [真机完成画面](verification/device-batch-completed.png) 与 [逐份机器摘要](verification/device-batch-summary.json)。报告的 `visual` 仍全部为 `pending`，不以计数替代逐帧画面核对。
