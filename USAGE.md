# SVGAPlayer-swift 使用说明

本文按「接入 → 画面 → 播放 → 逐帧操作 → 动态内容 → 诊断」的顺序介绍组件，也列出 demo 的列表、批播和宿主对照功能。代码片段中的异步操作应放在调用方的异步方法或 `Task` 中。

快速查阅：[接入](#2-接入组件) · [画面](#3-画面选择显示方式) · [加载与缓存](#4-加载文件与管理缓存) · [播放](#5-播放控制) · [逐帧](#6-进度与帧级操作) · [动态内容](#7-动态内容图片文本隐藏与恢复) · [诊断](#9-诊断当前到底执行到了哪一步) · [demo](#10-demo列表与单份详情) · [排错](#14-格式限制与排错)。

## 1. 功能一览

| 功能 | 可以做什么 |
| --- | --- |
| 文件加载 | 加载本地文件、Bundle 资源、HTTP / HTTPS 地址；支持取消 |
| SVGA 格式 | 读取 zlib protobuf、ZIP 内的 `movie.binary` 或旧版 `movie.spec` |
| 共享影片 | 取得不可变影片，读取画布、帧率、帧数、精灵、图片和音频信息；多播放器共享同一影片 |
| 解析缓存 | 内容摘要命中、在途解析共享、强制重新解析、绕过缓存、自定义预算、清缓存和统计 |
| 显示 | SwiftUI、UIKit、AppKit；透明背景；自动适应宿主尺寸与屏幕比例 |
| 播放 | 播放、暂停、从头重播、有限或无限循环、选择结束后的画面 |
| 定位 | 按整数帧或 `0...1` 进度定位、上一帧、下一帧、重绘 |
| 画布适配 | 完整显示、填满裁切、拉伸、原始大小 |
| 动态内容 | 根据真实精灵 key 替换图片、替换文本、隐藏、恢复源内容、取消未完成替换 |
| 矢量与遮罩 | 路径、圆角矩形、椭圆、填充、描边、虚线、clip 和 matte 遮罩 |
| 音频 | 播放源文件内的音频，随暂停、定位和循环按帧对齐 |
| 诊断 | 加载报告、缓存统计、播放快照、GPU 与系统呈现数据、有界帧事件和内容事件 |
| demo 工具 | 全量资源预览、搜索、刷新、单份详情、完整目录批播、双宿主对照、JSON 导出与分享 |

## 2. 接入组件

### 环境与包

| 项目 | 要求 |
| --- | --- |
| Swift | 6.4；Swift 6 语言模式 |
| 系统 | iOS 26.0 或 macOS 26.0 及以上 |
| 包管理 | Swift Package Manager |
| 本地包目录 | `packages/SVGAPlayer-swift` |
| Library product | `SVGAPlayer-swift` |
| Swift 导入名 | `SVGAPlayer_swift` |
| protobuf 依赖 | 官方 SwiftProtobuf 1.39.0，由 SPM 管理 |

在 Xcode 中添加本地 package，并将 `SVGAPlayer-swift` product 加到使用它的 target。Swift 文件导入：

```swift
import Foundation
import SVGAPlayer_swift
```

### 三个主要对象

| 对象 | 职责 | 使用方式 |
| --- | --- | --- |
| `SVGALoader` | 将 URL 加载为影片，管理解析缓存 | 使用 `.shared`，也可以自建独立实例 |
| `SVGAMovie` | 保存不可变的影片内容 | 同一影片可以安装到多个播放器 |
| `SVGAPlayer` | 管理播放、定位、替换、音频和渲染 | 每个独立播放画面使用一个播放器 |

`SVGALoader` 和 `SVGAPlayer` 是 actor，跨隔离调用使用 `await`。显示视图在 MainActor 创建和使用。播放器应由页面或会话稳定持有，避免每次 SwiftUI `body` 更新都重新创建。

### 最少四步播放

以下假设 `url` 已指向一个真实 `.svga` 文件：

```swift
let player = SVGAPlayer()
let result = try await SVGALoader.shared.load(from: url)
try await player.install(result.movie)
try await player.play()
```

将同一个 `player` 传给下一节的显示视图。`install` 只准备并请求首帧，**不会自动播放，也不会等待首帧 GPU 完成**；准备成功后状态为 `paused`。

默认设置：播放 1 轮、完整显示画布、结束后停在最后一帧。

## 3. 画面：选择显示方式

### SwiftUI

页面导入 `SwiftUI`，在 MainActor 使用：

```swift
SVGAView(player: player)
    .frame(height: 280)
```

用 SwiftUI 的布局设置显示区域。影片画布大小与视图大小可以不同，由显示适配模式决定缩放方式。

### UIKit

在 MainActor 中创建，并通过 frame 或 Auto Layout 设置尺寸：

```swift
let animationView = SVGAUIKitView(player: player)
```

### AppKit

在 MainActor 中创建，并通过 frame 或 Auto Layout 设置尺寸：

```swift
let animationView = SVGAAppKitView(player: player)
```

三种入口均使用库的 Metal 显示能力。一个播放器只有一个当前显示目标；从 SwiftUI 切到原生宿主可以继续使用同一个播放器。需要同时显示两个独立画面时，创建两个播放器；二者仍可安装同一个 `SVGAMovie`。

未挂到窗口、隐藏、祖先隐藏或画布为零尺寸时，可能无法取得显示目标。此时不能根据 `playing` 状态断言画面已经显示，可查看 `drawableFailures` 和呈现事件。宿主挂载或尺寸变化会请求重绘；暂停时也可主动调用 `redraw()`。

iOS App 失去活动状态时，宿主会关闭 GPU 提交并等待此前提交被系统调度；重新激活时主动重绘。播放设置保持不变，后台 GPU 权限拒绝不会把影片永久标成失败。时间轴是否暂停仍由调用方控制，有限播放可能在后台经过末尾；需要回到前台继续原位置时，由页面生命周期调用 `pause()` / `play()`。

### 四种显示适配

对应 `SVGADisplayMode`，可以在播放或暂停时修改。

```swift
await player.changeDisplayMode(to: .aspectFit)
```

| 模式 | 详情页名称 | 效果 |
| --- | --- | --- |
| `.aspectFit` | 完整显示 | 保持比例，全部画布可见，空余区域透明；默认值 |
| `.aspectFill` | 填满裁切 | 保持比例填满视图，超出区域被裁切 |
| `.stretch` | 拉伸 | 宽高分别缩放，可能变形 |
| `.originalSize` | 原始大小 | 按源逻辑尺寸居中，不自动缩放；显示区域不够时会裁切 |

## 4. 加载文件与管理缓存

### 来源

| 来源 | 传给 `load(from:)` 的值 |
| --- | --- |
| Bundle | `Bundle.main.url(forResource:withExtension:)` 得到的 URL |
| 本地文件 | 对应文件的 `file://` URL |
| 网络 | HTTP 或 HTTPS URL；响应必须是 2xx，具体联网权限由宿主 App 配置 |

`load` 成功返回 `SVGALoadResult`：`movie` 是影片，`report` 是**这一次调用**的加载报告。它完成的是解析；图片像素、几何和音频的播放准备在 `player.install` 中完成。

### 三种加载策略

策略类型为 `SVGALoadPolicy`。

```swift
let result = try await SVGALoader.shared.load(from: url, policy: .useCache)
```

| 策略 | 行为 | 适用场景 |
| --- | --- | --- |
| `.useCache` | 命中同内容影片，或加入同内容的在途解析；没有时新解析并按预算缓存 | 正常加载，默认值 |
| `.reload` | 使同内容旧缓存或在途代数失效，重新解析，新结果仍可缓存 | 强制重新解析、排查旧结果 |
| `.bypassCache` | 独立解析，不读写解析缓存，也不加入共享解析 | 做独立加载对照 |

缓存按文件内容的 SHA-256 匹配，相同内容即使 URL 不同也可复用。命中缓存前仍会读取文件并计算摘要；它是**内存中的解析结果缓存**，不等于网络下载缓存、磁盘缓存或 GPU 纹理缓存。

### 独立预算与清缓存

```swift
let loader = SVGALoader(byteLimit: 64 * 1024 * 1024)
let result = try await loader.load(from: url)
let statistics = await loader.statistics
await loader.clearCache()
```

默认预算为 128 MiB，按最近使用顺序淘汰。负预算按 0 处理；预算为 0 时仍可共享在途解析，但不保留完成影片。单份影片超过缓存预算时仍可成功返回，只是不留在缓存中。

`clearCache()` 清除已缓存影片并使当前在途代数失效，**不会停止已经安装的播放器**。原等待者仍可能收到解析结果，但旧结果不会重新填回缓存。

### 取消与加载失败

```swift
let loading = Task {
    try await SVGALoader.shared.load(from: url)
}
loading.cancel()
```

取消一个等待者不会取消其他等待者；最后一个等待者取消后，库会取消对应的解析工作。取消是合作式的，在读取、摘要、解压和准备等阶段的检查点响应。

加载失败或取消都通过 `SVGALoadFailure.report` 取得本次结果：

```swift
do {
    let result = try await SVGALoader.shared.load(from: url)
    try await player.install(result.movie)
} catch let failure as SVGALoadFailure {
    let report = failure.report
    // report.status == .cancelled 表示加载取消；.failed 表示读取或解析失败。
} catch is CancellationError {
    // 安装准备也可能被取消。
} catch {
    // 安装阶段的资源或其他错误。
}
```

## 5. 播放控制

| 操作 | API | 实际效果 |
| --- | --- | --- |
| 准备影片 | `try await player.install(movie)` | 替换旧安装，清除旧动态内容，重置位置与轮数，准备后暂停 |
| 播放 / 继续 | `try await player.play()` | 暂停时继续；自然结束后调用会从头开始并重新计轮；已播放时不重复启动 |
| 暂停 | `await player.pause()` | 暂停时间轴和音频，保留当前位置与内容 |
| 回到开头并暂停 | `try await player.rewind()` | 定位第一帧，清零轮数并暂停 |
| 从头播放 | 先 `rewind()`，再 `play()` | 无论当前在哪一帧，都重新开始 |
| 清空 | `await player.clear()` | 取消准备和未完成替换，等待旧 GPU 工作，清空影片与画面；保留显示绑定供下次安装 |
| 清空的另一入口 | `try await player.install(nil)` | 使用安装 API 显式清空 |
| 页面退出 | `await player.shutdown()` | 清空并等待资源排空，再解除当前显示绑定 |

加载 URL 的任务由调用方持有。离开页面时，先取消并等待自己的加载任务，再 `await player.shutdown()`，避免外部加载完成后又安装影片。正常重新加载使用 `install` 或 `clear`；页面退出使用 `shutdown`，之后重新显示需要再次挂载宿主。

### 循环次数

对应 `SVGALoop`。

```swift
try await player.changeLoop(to: .finite(2))
try await player.changeLoop(to: .infinite)
```

`.finite(n)` 的 `n` 必须大于 0，表示本次播放的总轮数；`.infinite` 表示持续循环。改变设置不会清零已完成轮数；需要重新计轮时先调用 `rewind()`。demo 提供 1 轮、2 轮、无限，库可以使用任意合法有限次数。

### 播放结束后显示什么

对应 `SVGAEndBehavior`。

```swift
await player.changeEndBehavior(to: .holdLastFrame)
```

| 策略 | 效果 |
| --- | --- |
| `.holdLastFrame` | 留在最后一帧；默认值 |
| `.returnToFirstFrame` | 回到第一帧并停止 |
| `.clear` | 画面透明，仍保留影片，可再次调用 `play()` |

结束策略在**有限轮次自然结束时**生效。它与显示适配独立；`.clear` 结束策略也不同于 `player.clear()`，后者会移除已安装影片。

### 状态含义

| `SVGAPlaybackState` | 含义 |
| --- | --- |
| `.empty` | 尚未安装，或已经清空 |
| `.preparing` | 正在准备图片、几何和音频 |
| `.paused` | 准备好但没有推进时间轴 |
| `.playing` | 时间轴正在推进 |
| `.finished` | 有限轮次已自然结束 |
| `.failed` | 主准备或播放失败，查看快照的 `failure` |

## 6. 进度与帧级操作

### 两种定位方式

```swift
try await player.seek(toFrame: 10)
try await player.seek(toProgress: 0.5)
```

| 方式 | 合法范围 | 说明 |
| --- | --- | --- |
| 整数帧 `toFrame` | `0..<movie.frameCount` | 从 0 开始，最后一帧是 `frameCount - 1` |
| 进度 `toProgress` | 有限的 `0...1` | `0` 对应第一帧，`1` 对应最后一帧；按最近整数帧定位 |

未安装影片、越界或非有限进度会抛错。定位通常保留原来的播放 / 暂停状态；从 `finished` 定位会回到 `paused`。定位不清零轮数；需要从头重新计轮时用 `rewind()`。

`SVGAPosition` 同时给出 `frame`、`progress`、`seconds`。秒数是该帧起点，不一定等于影片总时长；单帧影片的位置进度为 0。

### 上一帧、下一帧和重绘

库通过暂停和整数帧定位组合逐帧操作，demo 会自动把目标限制在首尾帧之间：

```swift
await player.pause()
let snapshot = await player.snapshot
if let frame = snapshot.requestedPosition?.frame {
    try await player.seek(toFrame: max(0, frame - 1))
}
await player.redraw()
```

`redraw()` 只请求当前帧重绘，不推进时间轴。

详情页的进度滑杆拖动时只改变界面草稿，松手后提交一次进度定位。上一帧 / 下一帧记录整数 `frame`，滑杆记录 `progress`，两者不混用。

### 详情页的完整调试按钮

| 按钮 | 行为 |
| --- | --- |
| 上一帧 / 下一帧 | 暂停，按整数帧移动一步；到首尾时停在边界 |
| 回到开头并暂停 | `rewind()`，轮数归零 |
| 重绘当前帧 | `redraw()` |
| 只准备不播放 | 按正常缓存策略重载并安装，首帧完成后保持暂停 |
| 走缓存重载 | 按 `.useCache` 重载，复用同一播放器并自动播放 |
| 强制重新解析 | 按 `.reload` 重载并自动播放 |
| 清空并取消未完成替换 | 取消页面加载、安装准备和替换，清空播放器 |

## 7. 动态内容：图片、文本、隐藏与恢复

### 先取得真实 key

```swift
let keys = result.movie.spriteKeys
```

所有替换均使用影片真实精灵 key。不存在的 key 会抛错；同名 key 有多个精灵实例时一起生效。无 key 的文件不会获得虚构槽位。图片资源字典的 key 和精灵 key 不一定相同，替换时以 `spriteKeys` 为准。

### 替换图片

```swift
try await player.replaceImage(with: imageData, forKey: key)
```

`imageData` 是可被系统 ImageIO 解码的图片编码数据，例如 PNG / JPEG；不是裸像素数组。当前取图片的第 0 帧，因此动画图片不会作为另一段动画播放。替换图片按精灵当前的布局矩形绘制，继续使用该精灵的变换、透明度和遮罩。

替换纹理覆盖该 key 的原位图和矢量内容。解码与上传发生在内容变化时，不会每帧重新解码。demo 通过系统文件选择器读取图片，再调用同一 API。

### 替换文本

```swift
try await player.replaceText(
    with: SVGAText(
        "欢迎使用\nSVGA",
        fontSize: 24,
        fontName: nil,
        color: SVGAColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
    ),
    forKey: key
)
```

| `SVGAText` 参数 | 含义 | 默认值 |
| --- | --- | --- |
| `string` | 文本内容，支持换行 | 必填 |
| `fontSize` | 源画布坐标中的字号，有限且 `0 < fontSize <= 4096` | 24 |
| `fontName` | Core Text 字体名称；`nil` 使用系统字体 | `nil` |
| `color` | `SVGAColor` 的 RGBA 颜色 | 不透明白色 |

文本居中排版，按该 key 找到的第一个正尺寸布局栅格化；找不到时以影片画布作为准备尺寸。最终能否看见仍由当前精灵布局、透明度和遮罩决定。文本 UTF-8 长度最多 65,536 字节，超出返回替换失败。

`SVGAColor(red:green:blue:alpha:)` 的分量使用 `0...1`，`alpha` 默认 1；构造时有限值会钳制到该范围，非有限值归零。其公开属性为 `red`、`green`、`blue`、`alpha`。

库支持字号、字体和颜色；当前 demo 的输入框只提供文本内容，使用默认样式。当前没有富文本、自定义文本对齐或文字跑马灯 API。

### 隐藏、恢复、取消

| 操作 | API | 效果 |
| --- | --- | --- |
| 隐藏 | `try await player.hideSprite(forKey: key)` | 隐藏该 key 的源内容和替换内容，撤销该 key 的未完成替换 |
| 恢复源内容 | `try await player.restoreSprite(forKey: key)` | 移除替换、取消该 key 未完成请求，恢复源内容和可见性 |
| 取消未完成替换 | `await player.cancelContentRequests()` | 取消并等待所有未完成替换；已成功安装的替换保持不变 |

同一 key 后发出的替换意图优先，旧准备结果不能覆盖新内容；隐藏、恢复和重新安装也会使相关旧请求失效。替换成功后请求重绘，旧版本的帧完成不会成为新的有效显示位置。

替换失败不自动终止整段播放，也不写入主播放 `failure`；未成功应用的替换不会覆盖已经生效的内容。查看 `player.contentEvents` 区分成功、失败、取消和丢弃；单纯没有抛错也不能替代事件中的“已应用”证据。

## 8. 音频、矢量与影片信息

### 音频

源文件含音频时，安装阶段会准备音频。播放、暂停、定位、循环和退出会同步处理音频，音频不进入 GPU。

`SVGAAudioClip` 的 `key` 对应 `audioData`，在 `[startFrame, endFrame)` 播放；`startTimeMilliseconds` 表示音频文件内的起播偏移。音频附件缺失或准备失败属于安装错误。当前没有独立音量、静音、音轨选择或外部音频替换 API。

### 矢量与遮罩

支持路径、圆角矩形、椭圆；填充、描边、线帽、连接、尖角限制、虚线和形状变换。`keep` 帧复用前一份实际形状。

支持精灵局部 clip 路径、matte 遮罩和连续 matte 组。路径几何在准备阶段缓存，遮罩在 GPU 完成。循环 matte 引用会报错。矢量使用单采样 winding stencil，当前未提供 MSAA 开关。

### 可读取的影片信息

| `SVGAMovie` 属性 | 含义 |
| --- | --- |
| `identity` / `version` | 原文件 SHA-256 / 源版本文本 |
| `size` | 源逻辑画布尺寸 |
| `frameRate` / `frameCount` / `duration` | 帧率 / 总帧数 / 一轮总秒数 |
| `sprites` / `spriteKeys` | 按绘制顺序排列的精灵 / 去重排序后的非空精灵 key |
| `images` | 图片资源 key 到编码数据的映射 |
| `audioClips` / `audioData` | 音频片段 / 音频 key 到编码数据的映射 |
| `accountedBytes` | 解析缓存计费字节，包含资源与模型估算；不是进程内存 |

`SVGASprite` 可读取 `key`、`matteKey`、`frameCount`。`matteKey == nil` 表示没有精灵遮罩。精灵帧数可能少于或多于影片总帧数：少于时播放保留最后状态，多出的尾帧不扩展影片时长。

影片通过加载器创建，内部帧、路径、纹理和图层实现不作为公开修改接口。

## 9. 诊断：当前到底执行到了哪一步

```swift
let snapshot = await player.snapshot
let diagnostics = await player.diagnostics
let contentEvents = await player.contentEvents
let cache = await SVGALoader.shared.statistics
```

这些都是适合低频读取的值快照。demo 约每 250ms 刷新一次；库不通过逐帧 `print` 或同步写文件输出日志。

**请求位置、GPU 完成和系统呈现是三个不同阶段。** `playing` 只说明时钟推进，GPU 完成只说明命令执行；系统实际显示需看独立呈现回调，画面是否正确还需查看真实画面。

可选字段的 `nil` 表示未执行、未观测或不适用；JSON 中通常省略该字段，不能当成 0。耗时和单调时间的原始单位均为秒。单调时间用于同一运行内比较，不是墙钟日期。

### 加载报告：`SVGALoadReport`

| 字段 | 含义 |
| --- | --- |
| `requestID` / `sourcePath` | 本次请求身份 / 实际文件路径或网络 URL |
| `policy` / `status` | `SVGALoadPolicy` 请求策略 / `SVGALoadStatus` 的 `succeeded`、`failed`、`cancelled` |
| `sha256` / `sourceBytes` | 输入摘要 / 输入字节数；未完成对应阶段时为 `nil` |
| `cachePath` | `SVGACachePath`：`notReached` 未到缓存查询、`hit` 命中、`miss` 新解析、`joined` 共享等待、`bypassed` 绕过 |
| `readSeconds` / `digestSeconds` | 读取耗时 / 摘要耗时 |
| `parseSeconds` | 本请求启动的解析耗时；命中或加入共享解析时为 `nil` |
| `sharedWaitSeconds` | 加入共享解析后的等待耗时；其他路径为 `nil` |
| `totalSeconds` / `error` | 总耗时 / 失败描述 |

### 缓存统计：`SVGACacheStatistics`

| 字段 | 含义 |
| --- | --- |
| `hits` / `misses` / `shared` | 完成缓存命中数 / 新建可缓存解析数 / 加入共享解析的请求数 |
| `parses` / `inFlight` | 实际启动解析数（含绕过）/ 尚未完成的实际任务数（含正在取消） |
| `evictions` / `invalidations` / `discardedResults` | 预算淘汰数 / 显式失效数 / 失效任务迟到完成数 |
| `failures` / `cancellations` | 返回给调用者的失败数 / 取消数 |
| `retainedMovies` / `retainedBytes` / `byteLimit` | 当前缓存份数 / 计费字节 / 预算上限 |

### 播放快照：`SVGAPlaybackSnapshot`

| 字段 | 含义 |
| --- | --- |
| `playerID` / `installationID` | 播放器永久身份 / 本次安装身份；重新安装会换后者 |
| `movieIdentity` / `state` | 当前影片 SHA-256 / 控制状态 |
| `requestedPosition` | 最新请求位置，包含 `frame`、`progress`、`seconds` |
| `gpuCompletedPosition` | 最近仍有效的 GPU 完成位置，未完成为 `nil` |
| `duration` | 源影片一轮秒数，未安装为 `nil` |
| `completedIterations` | 自然跨过时间轴末端的轮数 |
| `completedWholeIterations` | 从开头连续经过的完整轮数；seek 跳过的轮次不计入 |
| `loop` / `endBehavior` / `displayMode` | 当前循环、结束策略、显示适配 |
| `revision` / `failure` | 定位或内容版本 / 主准备与播放错误 |

`player.id` 可直接读取，对应 `snapshot.playerID`。清空后控制快照不再包含影片，但 `diagnostics` 会保留最近安装证据，下一次安装再重置；读取诊断时应核对身份。

### 准备与呈现：`SVGAPlaybackDiagnostics`

| 字段 | 含义 |
| --- | --- |
| `playerID` / `installationID` / `movieIdentity` | 诊断属于哪个播放器、安装和影片 |
| `preparationSeconds` | 影片资源准备耗时 |
| `firstSubmitSeconds` / `firstGPUCompletionSeconds` / `firstPresentationSeconds` | 从安装开始到首次提交 / 首次有效 GPU 完成 / 首次有效系统呈现 |
| `latestFramePreparationSeconds` / `maximumFramePreparationSeconds` | 最近 / 最大单帧 CPU 准备与编码耗时 |
| `totalGPUSeconds` | 驱动提供的有效 GPU 时间累计；无法观测时为 `nil` |
| `submittedCommands` / `gpuCompletions` | 实际提交数量 / 成功的影片 GPU 完成数量 |
| `systemPresentations` | 系统非零时间呈现回调数；尚未收到为 `nil` |
| `stalePresentations` / `zeroTimeSkips` | 过期呈现数 / 零时间回调跳过数 |
| `coalescedRequests` / `discardedResults` / `drawableFailures` | 请求合并数 / 旧结果丢弃数 / 显示目标获取失败数 |
| `gpuUnavailableSkips` | 提交时平台已停用，或系统返回 Metal `notPermitted` 的跳过次数；不增加 GPU 完成数 |
| `latestCPUInputBytes` / `retainedGPUInputBytes` | 最近帧 CPU 动态输入字节 / GPU 输入纹理与几何的留存计费 |
| `events` | 最后 128 条帧阶段事件 |

当前 iOS Simulator SDK 不提供系统呈现回调，模拟器相关呈现字段保持 `nil`；真机或 macOS 也可能收到零时间回调，此时只计入 `zeroTimeSkips`。计费值均不是进程 RSS，不能用作整个 App 的内存占用。

### 帧事件与内容事件

`SVGAFrameEvent` 包含 `stage`、`monotonicTime`、`requestID`、`position`、`durationSeconds`、`accepted`。阶段 `SVGAFrameStage` 为：

| 阶段 | 意义 |
| --- | --- |
| `prepared` / `submitted` | 输入准备完成 / 命令已提交 |
| `gpuCompleted` / `presented` | GPU 完成 / 系统回报非零呈现时间 |
| `presentationSkipped` / `drawableUnavailable` | 零时间呈现跳过 / 没有可用显示目标 |
| `gpuUnavailable` | 平台暂停提交或权限暂不可用，恢复后可重绘 |
| `coalesced` / `discarded` | 旧待提交请求被合并 / 过期结果被丢弃 |

`accepted` 表示是否仍符合当前安装和内容版本；整体准备事件的 `requestID`、`position` 等可以为 `nil`。

`SVGAContentEvent` 包含 `requestID`、`installationID`、`key`、`operation`、`status`、`monotonicTime`、`durationSeconds`、`detail`。`SVGAContentOperation` 为 `image`、`text`、`hide`、`restore`；`SVGAContentStatus` 为 `succeeded`、`failed`、`cancelled`、`discarded`。最多保留 256 条，错误或丢弃原因在 `detail` 中。

上述诊断结构以及设置、状态、事件枚举支持 `Codable`；影片本身、加载结果和错误包装并不都能直接编码。导出时选择报告或快照，例如：

```swift
let snapshot = await player.snapshot
let data = try JSONEncoder().encode(snapshot)
```

## 10. Demo：列表与单份详情

打开 `SVGAPlayer-swift-demo/SVGAPlayer-swift-demo.xcodeproj`，运行 `SVGAPlayer-swift-demo` scheme。macOS 使用一个窗口。

### 列表

- 扫描 App Bundle 的 `resoureces` 目录，收集全部 `.svga`；当前仓库有 133 份。
- 每行显示库预览、文件名、字节大小、解析摘要或失败信息；失败文件仍可进入详情。
- 搜索文件名，标题显示「当前匹配数 / 总数」。
- 工具栏刷新和系统下拉刷新都重新扫描目录；扫描失败会显示错误。
- 每个候选持有自己的预览会话，无“最多 N 行”名额；搜索、滚动离屏和进入详情不会为了名额卸掉播放器。
- “播放全部”使用完整目录，搜索不会缩小批播集合。

### 详情

详情自动加载并播放，区域依次为：画面、播放控制、帧级诊断、动态内容、宿主对照入口、诊断快照和控制台。

画面显示状态、画布尺寸、时长、fps、帧数；SwiftUI / UIKit / AppKit 宿主切换复用同一个播放器。播放器准备好后才开放需要影片的操作。离开详情会取消加载与播放，并等待资源排空。

首次有效 GPU 完成的等待上限为 **15 秒，包含读取、解析和安装准备**；超时明确显示错误。这是 demo 的验收策略，库的 `load` / `install` 没有固定 15 秒限制。列表尚未挂载的预览不因没有 drawable 被算作首帧超时。

### 诊断面板与控制台

面板分为文件与构建、播放状态、载入与缓存、准备与呈现、资源五组。还会显示相对路径、完整路径、字节数、SHA-256、runID、播放器与安装身份、系统、CPU、Debug / Release、构建号和构建标记；没有构建标记显示“未提供”。文本支持选择复制。

控制台最多保留 128 条宿主操作、128 条库帧事件、256 条内容事件。每次宿主操作带时间、操作名、参数，替换带 key。可搜索、显示 / 隐藏正常帧事件、冻结 / 继续显示；筛选和冻结不删除导出内容，也不会暂停播放。

## 11. Demo：播放全部

1. 在列表点“播放全部”，固化本轮完整目录计划。
2. 按文件名的稳定数字顺序逐个播放，每份 1 轮，整个批次只复用一个播放器。
3. 单份失败或超时记录结果并继续下一份；取消或离开页面停止当前批次。
4. 每份尝试结束保存单份报告，批次结束或取消后保存整批报告。

单份整体时间上限为 `max(20, 2 × 源时长 + 10)` 秒，同时加载阶段仍受前述 15 秒首帧策略约束。

页面显示计划数、已尝试数、完整一轮数、失败数、当前文件、唯一画布、诊断与完整计划。未运行项始终保留，并显示“尚未运行”；取消不计失败，也不把未运行项记成成功。可点击“导出整批报告”和“分享整批报告”。

## 12. Demo：SwiftUI / 原生宿主对照

从详情的“SwiftUI / 原生宿主对照”进入。此页才创建两个独立会话：一份 SwiftUI，一份当前平台的 UIKit 或 AppKit，加载同一文件，默认无限播放。

| 控件 | 用途 |
| --- | --- |
| 挂载显示目标 | 同时挂上 / 移除两个显示视图，保留各自会话 |
| 隐藏原生祖先 | 检查原生宿主在祖先隐藏时的行为 |
| 画布高度 | 在 0…420 逻辑点之间调整，覆盖零尺寸与恢复场景 |
| 两组帧级诊断 | 分别控制各自播放器 |
| 两份诊断面板 | 比较独立 playerID、安装、GPU 与呈现数据 |

两份会话共用这次对照的 runID，但播放状态独立，导出文件按 playerID 区分。

## 13. Demo：JSON 导出、分享与启动参数

### 导出与保存

在诊断面板点“导出 JSON”，写成功后显示真实路径并开放分享；导出失败会显示单独错误。普通详情在播放进入结束状态时自动归档；加载失败也会归档。列表预览不自动把播放写成完整验收报告。

保存位置在 **当前 App 容器** 的：

```text
Library/Caches/SVGASwiftReports/<runID>/
```

详情文件为 `detail-<playerID>.json`；批播单份为 `<文件名>.json`，整批为 `batch.json`。同一次详情或整次批播共用一个 runID。报告异步原子写入，最多保留 10 个 run 目录；Caches 也可能被系统清理，需要长期留存时请分享出去。

### 报告字段怎么看

单份报告包含 `runID`、`resource`、`environment`、`endReason`、四个阶段字段、`load`、`snapshot`、`diagnostics`、`cache`、`actions`、`contentEvents`、`error`。`resource` 记录文件名、相对路径、完整 URL 和字节数。

| 阶段字段 | 值及含义 |
| --- | --- |
| `parsing` | `succeeded`、`failed`、`cancelled` 或 `notExecuted` |
| `rendering` | 有成功 GPU 完成才是 `completed`；否则为 `notCompleted` |
| `playback` | 完整自然结束才是 `finished`；预览为 `preview`；seek 跳过后结束可能为 `endedAfterSeeking`；其他情况保留实际状态 |
| `visual` | 默认 `pending`，表示尚无人工画面结论 |

整批报告包含 `runID`、`planned`、`attempted`、`cancelled`、`completedMovies`、`failedMovies`。`planned` 保留全部计划，`attempted` 只包含实际开始的尝试。

JSON 导出与分享是 demo 功能。库提供可编码诊断值，接入自己的 App 时由调用方决定保存和分享方式。

### 启动参数

在 Xcode Scheme 的 Run → Arguments 中添加：

| 参数 | 效果 |
| --- | --- |
| `--svga-sample=12.svga` | 直接打开该文件详情 |
| `--svga-sample=65.svga --svga-host-lab` | 直接打开该文件双宿主对照 |
| `--svga-batch` | 直接开始完整目录批播；与样本参数同时存在时优先 |

参数每次启动只应用一次，返回列表不会再次自动跳转。文件名必须与列表中的身份完全一致；不存在时显示错误。

### 常用 accessibilityIdentifier

| 位置 | 身份 |
| --- | --- |
| 列表项 / 刷新 / 播放全部 | `catalog.item.<文件名>` / `catalog.refresh` / `catalog.playAll` |
| 详情画布 / 滑杆 | `detail.canvas` / `detail.progress` |
| 帧级诊断 / 动态内容 / 宿主入口 | `detail.debugControls` / `detail.contentControls` / `detail.hostLab` |
| 诊断 / 控制台 / 导出 / 报告路径 | `detail.diagnostics` / `diagnostics.console` / `diagnostics.export` / `diagnostics.reportPath` |
| 批播画布 / 诊断 / 计划项 | `batch.canvas` / `batch.diagnostics` / `batch.item.<文件名>` |
| 宿主对照 / 两个画布 | `hostLab` / `hostLab.swiftUI.canvas` / `hostLab.native.canvas` |

## 14. 格式、限制与排错

### 支持范围与固定预算

| 项目 | 当前支持或上限 |
| --- | --- |
| 容器 | 整段 zlib protobuf；单卷 ZIP stored / DEFLATE，含中央目录、data descriptor、CRC 校验 |
| ZIP 影片条目 | `movie.binary` 优先，其次 `movie.spec`；缺少两者报错 |
| SVG 路径命令 | `M/L/H/V/C/Q/Z` 及小写；支持相对坐标、重复参数、科学计数法 |
| 输入与解压总量 | 各最多 256 MiB |
| 源画布 | 两轴大于 0，各不超过 32,768 逻辑点 |
| 源 fps / 总帧数 / 精灵数 | `1…1000` / `1…100000` / 最多 10,000 个精灵 |
| 单项图片 / 文本栅格 | 最多 16,777,216 像素；文本准备两轴各不超过 8192 |
| 显示目标 | 两轴各不超过 8192 物理像素，总像素不超过 16,777,216 |
| 单影片 GPU 输入 | 源纹理、几何和已安装替换合计最多 512 MiB |
| GPU 遮罩附件 | 最多 256 MiB |
| 矢量复杂度 | 有轮廓数、细分点与顶点数上限；超限报错 |

ZIP64、加密、多卷 ZIP、其他 SVG 路径命令会明确失败。当前没有倒放、变速、独立播放区间、公开 CALayer drawing block、全片图片 / 视频导出 API。库不依赖 ProtobufObjC、SSZipArchive、CocoaPods 或旧播放器。

### 错误类型

| `SVGAError` | 应检查什么 |
| --- | --- |
| `.invalidData(String)` | 文件损坏、字段非法、附件缺失、区间或结构错误 |
| `.unsupported(String)` | 当前未实现的容器或路径特性 |
| `.resource(String)` | 图片、文本、音频或 GPU 资源准备失败、预算超限 |
| `.invalidOperation(String)` | 未安装就操作、帧或进度越界、轮数非法、key 不存在 |

可通过 `errorDescription` / `localizedDescription` 取得说明。加载器统一用 `SVGALoadFailure` 携带自己的报告；安装和操作还可能抛出取消或底层系统错误，不应只处理 `SVGAError`。

### 常见现象

| 现象 | 排查方式 |
| --- | --- |
| 解析成功但还没画面 | 确认执行了 `install`，宿主已挂载且非零尺寸，再看 GPU 完成与 drawable 数据 |
| 状态 playing 但看不到 | 查看宿主 / 祖先隐藏、布局、`drawableFailures`，以及当前帧自身透明度和遮罩 |
| 准备好后没有动 | `install` 不自动播放，需要调用 `play()` |
| 结束清空后还能重播 | 这是 `.clear` 结束策略，保留了影片；显式 `player.clear()` 才移除影片 |
| 替换没有变化 | 使用真实精灵 key；查看内容事件；确认目标当前可见、有正尺寸且未被遮罩挡住 |
| 系统呈现为 nil | 可能是模拟器不支持回调，或尚无有效回调；不能用 GPU 完成补这个值 |
| 手动跳到尾部却不是 finished 报告 | 跳过的轮次没有完整播放证据，查看 `completedWholeIterations` |
| 清缓存后影片还在播放 | 缓存与已安装资源独立；停止并释放当前影片使用 `clear()` 或 `shutdown()` |
| 详情 15 秒超时 | 对照加载阶段、主错误、宿主挂载、首次提交和首次 GPU 完成，确定卡在哪一段 |
| 前几行切后台后报 Metal Code=7 | 这是 GPU 后台提交权限拒绝；当前版本会暂停提交并恢复重绘，可在 `gpuUnavailableSkips` 查看切换瞬间的拒绝记录；其他 GPU 错误仍需排查 |
| 主播放已经 failed | 保存诊断后重新安装或重载影片再试；只调用 `play()` 不会清除旧的主错误 |

## 15. 验证与源码入口

库测试：`swift test --package-path packages/SVGAPlayer-swift`。demo 的构建、运行与画面核对在 Xcode 完成。当前验证记录和真实截图见 [验证记录](docs/verification.md)。

查看实现时，从这些文件对应到功能：

| 文件 | 功能 |
| --- | --- |
| `SVGALoader.swift`、`SVGALoadDiagnostics.swift` | 加载、缓存、加载报告和缓存统计 |
| `SVGAMovie.swift` | 影片、精灵、音频、颜色和公共错误 |
| `SVGAPlayer.swift`、`SVGAPlayer+Content.swift` | 播放控制、资源生命周期和动态内容 |
| `SVGAPlaybackDiagnostics.swift` | 全部播放设置、状态、快照与事件定义 |
| `SVGAView.swift`、`SVGAUIKitView.swift`、`SVGAAppKitView.swift` | 三种显示入口 |
| `DemoDetailView.swift`、`DemoSession.swift` | 本文对应的详情操作和页面生命周期示例 |

源码以当前仓库为准。没有公开的功能不要通过内部类型或旧 Objective-C API 调用。
