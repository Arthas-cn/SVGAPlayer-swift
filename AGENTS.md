# Agent 约定

本文件是 Cursor 与 Codex 的同一份项目约定。Codex 只自动读取仓库根目录的 `AGENTS.md`，不读取 `.cursor/rules/*.mdc`。Cursor 的规则入口只负责指向本文件。改约定时只改这里。

本仓库日常用中文沟通。本仓库没有安装第三方 skill，不要假装存在 `$swift-concurrency-pro` 或其他 skill，也不要把 `/Users/arthas/shibo/iOSProject/libpag-swift` 的 skill 复制进来。公开 API 的命名要求已经写在 R4。

目标是用 Swift **重写** [SVGAPlayer-Lite](https://github.com/Arthas-cn/SVGAPlayer-Lite)。这不是把 Objective-C 头文件逐符号译成 Swift，也不是给旧库做永久包装。要同时解决性能、SwiftUI 显示和公开 API。

只读参考，不要改，也不要加成编译依赖或运行时依赖：

- 行为与 `.svga` 证据：`/Users/arthas/shibo/iOSProject/SVGAPlayer-Lite`
- 工程组织、Metal 宿主拆分、SwiftUI 接入方式可对照 `/Users/arthas/shibo/iOSProject/libpag-swift`。不要把它的 PAG 类型、`.pag` 布局或领域 skill 搬进本仓库

库在仓库根，清单只有一份 `Package.swift`。源码、测试和 schema 使用 SPM 默认布局：`Sources/SVGAPlayer_swift`、`Tests/SVGAPlayer_swiftTests`、`Schema`（schema 不要放进 `Sources`）。验证用的 demo 在 `SVGAPlayer-swift-demo`。不要建名为 `packages` 或 `Packages` 的目录，也不要再加第二份 `Package.swift`。默认不区分大小写的磁盘上，这个目录名就是 SwiftPM 保留的 `Packages`，Xcode 会把其中的源码从导航器藏掉；只删一份清单或只改 `path` 仍然不会显示。

以下 R1–R3、R8–R9 与技术栈始终遵守。R4–R7、R10–R11 按用户意图套用，不必用户重贴模板。

## 技术栈

- Swift 6.4（Xcode 自带编译器）。工程写 `SWIFT_VERSION = 6.4`。按严格并发写，并使用 Swift 6.4 语法。不要改回 `6.0` 或 5。库与 demo 都开启 Approachable Concurrency。**库的默认 actor isolation 为 `nonisolated`。**
- 最低系统：iOS 26.0、macOS 26.0。可以使用这两个系统的 API。不要为更早系统加 `#available` 或兼容层，除非任务明确要求。不要主动扩到 watchOS、tvOS、visionOS。
- 包：SPM。`swift-tools-version` 最低 6.4；语言模式 `swiftLanguageModes: [.v6]`（没有 `.v6_4`）。`platforms` 声明 iOS 26 与 macOS 26。
- demo 以 target 为准：`IPHONEOS_DEPLOYMENT_TARGET = 26.0`，`MACOSX_DEPLOYMENT_TARGET = 26.0`，`SWIFT_VERSION = 6.4`。Xcode 模板里的部署版本和 `SWIFT_VERSION = 5.0` 不是基线。demo 可以 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。库 target 必须默认 `nonisolated`，不要为了少写派发把库标成 `@MainActor`。
- 终态不要依赖 `ProtobufObjC.xcframework`、SSZipArchive、CocoaPods，也不要链上 SVGAPlayer-Lite。

## 重写范围

旧播放器是一精灵一层：`SVGAContentLayer`、`SVGABitmapLayer`、`SVGAVectorLayer`、`CATextLayer`，由显示链路在主线程改 transform、alpha、遮罩和路径。公开入口是 `UIView` 子类、ObjC delegate、`NSRunLoopMode` 和接收 `CALayer` 的 drawing block。

新库按职责拆开。具体类型名由后续设计决定，本文件不规定签名。

| 旧概念 | 职责 |
| --- | --- |
| `SVGAParser` | 异步、可取消地把 `.svga` 载入为可共享的影片 |
| `SVGAVideoEntity` | 不可变影片：画布、帧率、帧数、精灵、图片、音频 |
| `SVGAPlayer` | 播放控制与显示宿主分开。宿主不是唯一入口 |
| `SVGAImageView` | 便捷显示，不另写一套播放器 |
| `setImage` / `setAttributedText` / `setHidden` | 按精灵 key 替换内容 |
| `setDrawingBlock` | 不移植。公开 API 不接收 `CALayer` |
| delegate、`loops == 0`、`fillMode` 字符串、`mainRunLoopMode` | 不保留这些形状。循环用明确的有限或无限；帧序号和 `0...1` 进度在 API 上分开 |

SwiftUI、UIKit、AppKit 都要能播。demo 用库的显示能力验证，不在 App 里再实现一个播放器。内部解码器、纹理和图层实现默认不要 `public`。值类型优先；共享影片、播放会话和 GPU 资源才用引用类型。

## 性能与 Metal

播放合成用 **Metal**，直接画到显示目标。位图解码一次后上传纹理，每帧更新变换和透明度。矢量路径细分或缓存成几何，遮罩在 GPU 完成。不要每帧重建 `CAShapeLayer`，也不要恢复「一精灵一个 CALayer」。

热路径不要先离屏再拷贝，也不要为播放把像素读回 CPU。文本和动态图片只在内容变化时栅格化成纹理。音频按帧对齐，不进 GPU。解析 zip / protobuf、图片解码可以在后台做，并且必须能取消；迟到结果不得覆盖更新的帧或替换。

平台层只保留挂 Metal drawable 的薄宿主。不要引入 OpenGL。旧 `SVGAExporter` 的整段出图不是播放必须能力；若以后做，单独走导出路径，不得反过来规定播放架构。

## `.svga` 证据

`.svga` 有两种容器，以 `SVGAParser` 为准：zip（内有 `movie.binary` 或 `movie.spec`，以及图片等资源），或整段 zlib inflate 后的 protobuf。字段号、条目名和帧语义以 SVGAPlayer-Lite 源码或官方规格为准，注释里写清文件与符号。

没有证据就走失败路径或标成未实现。不要凭记忆写 tag、偏移或压缩细节，也不要手写一段自称合法的假二进制。测试夹具用真实 `.svga`，或明确是损坏输入。

## R1 改动边界

- 只改完成当前任务所需的代码，不顺手重构、不改无关行为。
- 沿用已有模块划分、命名和模式。库保持仓库根的默认 SPM 布局（`Sources/`、`Tests/`、`Schema/`），demo 保持 `SVGAPlayer-swift-demo/`。不要新增 `packages/` 或 `Packages/`。
- 不引入任务未要求的依赖或新框架。
- 不编造仓库里不存在的类型、API、文件或配置。不凭记忆编造 `.svga` 二进制布局。
- 未要求时不改工程配置、不提交 git、不推远程。

## R2 动手前与交付后

动手前（实现类任务，简短即可）：

1. 用一两句话复述需求。
2. 标出缺失或含糊的点；会阻塞实现时先问，不猜着写。
3. 说明计划改哪些文件 / 模块。

交付后：

1. 说明实际改了什么、为什么。
2. 给出如何验证。库用 `swift test`；只有 demo 才编译、安装或手动看界面。
3. 列出未做事项或已知风险。
4. 对照 R8：声明有 `///`，关键分支有 `//`，每个测试用例说明测的场景。缺注释不算完成。

## R3 证据与不确定性

区分四件事：仓库里能看到的事实、SVGAPlayer-Lite 源码或官方规格能证实的事实、合理推断、尚未验证的假设。

做不到的事先说，不把猜测写成已证实。字节级行为没有证据就不要实现成「先能跑」。引用代码时指向具体文件与符号。

## R4 实现功能

用户要写或改功能时：

1. 复述需求，标出含糊点、受影响模块和最小可维护方案。
2. 再改代码。重要设计选择用一两句说明。
3. 补上与改动匹配的测试。库沿用 Swift Testing。
4. 点出边界情况，并给简短验证清单。
5. 约束同 R1：不扩依赖、不改无关行为。
6. 新写或改到的 Swift 遵守 R8 和 R9。没有按 R8 写注释不得声称实现完成。

公开 API 按 Swift API Design Guidelines：调用点读得通；有副作用用动词，无副作用用名词；不要 `get` / `set` 和 `initWith`。不要因为旧 SDK 是 class，就把所有状态都做成引用类型。

## R5 调试

用户报 bug、崩溃或异常行为时：

1. 先按概率列出原因，并写清每条依据（日志、代码、复现）。
2. 给出验证或排除假设的最快方法。
3. 再给最小、安全的修复，并说明副作用。
4. 建议回归点。
5. 不要一上来重写整段实现。

## R6 代码审查

用户要 review 时，按项评估：正确性、安全性、性能、可维护性（含 R8 注释、R9 体量）、错误处理、测试、边界情况。方法无 `///`、关键分支无 `//` 按可维护性列出，不要只检查公开 API。

每个问题写：严重度（严重 / 高 / 中 / 低）、为何重要、最小改法。

最后给：优先改的最多三项、已经做得好的地方、可能的架构风险。不为风格而建议大重构。

## R7 理解代码库

用户要摸结构、问从哪读起时：

先说清：整体结构、主要目录职责、入口、从文件到画面的数据流、包依赖、平台适配放在哪、测试怎么组织。

然后：一条典型播放路径如何走完；建议先读的最多五个文件；哪些区域复杂或风险高。

按刚进组的开发者来写，不假设读者已经熟悉本仓库或 SVGAPlayer-Lite 的 Objective-C 实现。

## R8 中文注释

新写或改到的手写代码必须让没参与实现的人读懂职责和关键取舍。缺注释视为未完成。不为凑规则给无关文件刷注释（仍守 R1）。

本规则对库、demo、测试通用。不要按模块再写一套注释细则。

**语言**

- 注释以中文为主。类型名、属性名、方法名、API 名保持英文。
- 专有名词可夹英文：`Sendable`、Apple API。

**声明上必须用 `///`（访问级别不豁免）**

`internal` / `private` / `fileprivate` 与 `public` / `package` 同等要求。

1. 每个 `class` / `struct` / `enum` / `actor` / `protocol`，以及承担独立职责的 `extension`：做什么、不做什么、属于哪一层。
2. 每个存储属性：业务含义、合法范围或 `nil` 含义。不要只复述标识符。
3. 每个 `enum` case（含关联值）：何时选这一支、和相邻 case 有何差别、关联值是什么。不要把多个未注释的 case 挤在同一行。
4. 每个方法、初始化器、下标：做什么、关键参数与返回值、失败或取消时如何交还结果、重要前置条件。一行实现也要有 `///`。协议已用 `///` 说明、空默认实现可不再重复。
5. 改已有声明时同步改注释，禁止留下与行为相反的旧注释。

**方法体内必须用 `//` 写清非显然步骤**

写在步骤之前，说明为什么这样写，或必须遵守的约束。不要复述下一行代码在做什么。

判断标准：换一个没写过这段代码的人，只看标识符和类型，仍会问「为什么走这条路 / 为什么在这里停 / 为什么故意不做某件事」，就必须写 `//`。

需要写的是通用情况，例如：

- 类型表达不了的不变量：顺序、互斥、只生效一次、迟到结果必须丢掉
- 并发：隔离、可重入、暂停点前后状态、谁负责结束未完成的工作
- 失败：为何转成另一种错误、为何吞掉、为何让调用方自己停
- 故意不走某条路：跳过、提前结束、忽略某个输入

不必写：顺向赋值、普通遍历、`guard let` 解包成功后的直接使用。

```swift
/// 只接受与当前提交序号相符的结果；过期完成必须丢弃。
func finish(_ result: Result<Value, Error>, sequence: Int) {
    // 序号对不上：这是上一轮提交的迟到结果，写进去会覆盖新值。
    guard sequence == currentSequence else { return }
    storage = result
}
```

不要写：

- 复述标识符：`/// 用户名` 对着 `var username`。
- 给 `import`、纯布局、显而易见的赋值逐行加注。
- 在源码 `///` 里写 DocC 的 `## Overview` / `## Topics`。
- 用注释代替清晰命名或拆函数。
- 用「internal 不用写」「一行函数不用写」「测试方法名已经是文档」缩小本规则。

**测试**

- 测试类型头说明这一组覆盖哪类行为。
- 每个测试用例（`@Test`、`func test…`）必须有 `///`：写清测的是什么行为或场景、期望看到什么结果。不能只靠方法名或 `@Test("…")` 显示名。
- 测试体内的 `#expect` 不必逐条加注。准备数据或步骤有非显然约定时用 `//`。
- `Package.swift`、工程配置只注释非显然的自定义设置。

## R9 单文件体量

对手写 Swift 计全部行数（含空行与注释）。禁止删注释凑行数。超限先拆文件。禁止靠省略 `//`，或把多步挤成一行来压行数。

| 文件 | 软限制 | 硬限制 |
| --- | --- | --- |
| 生产代码（`Sources/`、`SVGAPlayer-swift-demo/`） | 700 行 | 1200 行 |
| 测试代码（`*Tests.swift` 等） | 1000 行 | 1200 行 |

- 生产代码接近 600 行、测试接近 900 行时按职责拆开，不要堆到软限制再拆。
- 达到硬限制必须先拆再继续写。交付时若已过软限制，说明原因和下一步拆法。

优先拆法：解析、影片模型、播放控制、Metal 合成、平台宿主分文件。合成求值不要写进 SwiftUI `View`。测试按场景拆 `*Tests.swift`，文件内用 `// MARK: -`。

不计入限制：生成代码、`project.pbxproj`、第三方源码，以及拆开会破坏完整性的单条巨型字面量。

不要在函数中间把文件切断，不要为了行数引入无意义的空壳类型，也不要把一个 SPM 模块拆成大量没有职责边界的小文件。

## R10 将本地 SPM 包接入 demo

库就是仓库根本身，只有这一份 `Package.swift`。demo 工程在 `SVGAPlayer-swift-demo/`，本地包相对该工程目录是 `..`。

1. 确认仓库根 `Package.swift` 声明了 library product `SVGAPlayer-swift`，名称与工程中的 product 名一致。
2. 将仓库根这个本地包及其 product 加入 `SVGAPlayer-swift-demo` target。不能仅凭源码目录出现在仓库里，或仅新增 product 名称，就认为接入完成。
3. 对每个使用该 product 的 target，检查其 `packageProductDependencies` 和 Frameworks 构建阶段均有对应引用。`XCLocalSwiftPackageReference` 的 `relativePath` 必须是 `..`。路径相对仓库，不能提交只在本机绝对路径上可解析的引用。不要把仓库根再做成 `PBXFileReference` 放进工程导航，否则工程会嵌套自己。
4. 若 demo 源码目录是文件系统同步文件夹，检查包源码没有被直接纳入 App target 编译。
5. 修改后检查工程文件语法、Xcode 的包解析，以及受影响 target 的构建。

## R11 包的位置

库已经在仓库根，使用 SPM 默认布局。不要再创建第二份包。

1. 唯一清单是仓库根 `Package.swift`。源码在 `Sources/SVGAPlayer_swift`，测试在 `Tests/SVGAPlayer_swiftTests`（夹具随测试目录，清单里 `.copy("Fixtures")`），schema 在仓库根 `Schema`，不要放进 `Sources`。
2. 不要新建名为 `packages` 或 `Packages` 的目录，也不要再加第二份 `Package.swift`。在默认不区分大小写的磁盘上，这个名字就是 SwiftPM 保留的 `Packages`，Xcode 会把其中的源码从导航器藏掉。只删一份清单或只改 `path` 仍然不会显示。
3. 不要为了“初始化包”再跑 `swift package init` 盖掉现有清单。改 product、依赖或 `swiftSettings` 只改仓库根这一份。
4. 清单保持：`swift-tools-version: 6.4`、iOS 26 与 macOS 26、`swiftLanguageModes: [.v6]`、库默认 `nonisolated`（`.defaultIsolation(nil)`）、Approachable Concurrency。依赖保持 SwiftProtobuf `exact: "1.39.0"`。
5. 在仓库根运行 `swift package describe` 与 `swift test`，不要再加 `--package-path`。需要供 demo 使用时，按 R10 接入，相对路径是 `..`。
