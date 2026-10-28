import Foundation
import CoreGraphics
import Metal

/// 按真实精灵 key 修改内容；准备工作可取消，失败不污染主播放状态。
extension SVGAPlayer {
    /// 解码并替换该 key 的内容；只有最后一次同 key 请求可以安装。
    public func replaceImage(with data: Data, forKey key: String) async throws {
        try await replace(.image(data), forKey: key, operation: .image)
    }

    /// 栅格化文本到源精灵尺寸；无正尺寸布局时使用源画布，仍只替换真实 key。
    public func replaceText(with text: SVGAText, forKey key: String) async throws {
        let size = scene?.movie.sprites.first(where: { $0.key == key })?.frames.first(where: {
            $0.layout.width > 0 && $0.layout.height > 0
        })?.layout.cgRect.size ?? scene?.movie.size ?? .zero
        try await replace(.text(text, size), forKey: key, operation: .text)
    }

    /// 隐藏指定精灵并使旧帧失效；同 key 未完成替换先取消，防止迟到图片重新出现。
    public func hideSprite(forKey key: String) throws {
        try immediate(key, operation: .hide) {
            var value = content[key] ?? MetalContent()
            value.hidden = true
            content[key] = value
        }
    }

    /// 恢复指定 key 的源内容和可见性，同时撤销该 key 的未完成替换。
    public func restoreSprite(forKey key: String) throws {
        try immediate(key, operation: .restore) { content.removeValue(forKey: key) }
    }

    /// 撤销所有未完成内容请求并等待其终结，不清除已经成功安装的内容。
    public func cancelContentRequests() async {
        contentVersions.removeAll()
        let tasks = Array(contentTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
    }

    /// 共享异步准备路径，动态内容结果跨暂停点后必须匹配安装和 key 意图。
    private func replace(_ input: ContentInput, forKey key: String, operation: SVGAContentOperation) async throws {
        let started = Monotonic.now, requestID = UUID()
        let installation = installationID
        do {
            try validateKey(key)
            if let old = contentVersions[key] { contentTasks[old]?.cancel() }
            contentVersions[key] = requestID
            let task = Task.detached(priority: .userInitiated) {
                let raster: RasterImage
                switch input {
                case .image(let bytes): raster = try SVGARasterizer.image(bytes)
                case .text(let text, let size): raster = try SVGARasterizer.text(text, size: size)
                }
                try Task.checkCancellation()
                let context = try MetalContext.shared.get()
                return try PreparedContent(texture: MetalMovie.texture(raster, device: context.device))
            }
            contentTasks[requestID] = task
            defer { contentTasks.removeValue(forKey: requestID) }
            let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard installationID == installation, contentVersions[key] == requestID else {
                appendContent(requestID, installation: installation, key: key, operation: operation,
                              status: .discarded, started: started, detail: "已被新内容或安装取代")
                return
            }
            let replacementBytes = prepared.texture.width * prepared.texture.height * 4
            let otherBytes = content.filter { $0.key != key }.values.reduce(0) {
                $0 + ($1.texture.map { $0.width * $0.height * 4 } ?? 0)
            }
            guard (scene?.accountedBytes ?? 0) + replacementBytes + otherBytes <= 512 * 1024 * 1024 else {
                throw SVGAError.resource("动态内容超过 GPU 输入预算")
            }
            content[key] = MetalContent(texture: prepared.texture)
            revision &+= 1
            requestFrame()
            appendContent(requestID, installation: installation, key: key, operation: operation,
                          status: .succeeded, started: started)
        } catch {
            let status: SVGAContentStatus = error is CancellationError || Task.isCancelled ? .cancelled : .failed
            appendContent(requestID, installation: installation, key: key, operation: operation,
                          status: status, started: started, detail: String(describing: error))
            throw error
        }
    }

    /// 同步隐藏/恢复也产生与异步替换一致的成功或失败事件。
    private func immediate(_ key: String, operation: SVGAContentOperation, change: () -> Void) throws {
        let started = Monotonic.now, requestID = UUID()
        do {
            try validateKey(key)
            if let old = contentVersions.removeValue(forKey: key) { contentTasks[old]?.cancel() }
            change()
            revision &+= 1
            requestFrame()
            appendContent(requestID, installation: installationID, key: key, operation: operation,
                          status: .succeeded, started: started)
        } catch {
            appendContent(requestID, installation: installationID, key: key, operation: operation,
                          status: .failed, started: started, detail: String(describing: error))
            throw error
        }
    }

    /// 不允许以不存在的槽位或未安装状态进行内容更新。
    private func validateKey(_ key: String) throws {
        guard scene?.movie.spriteKeys.contains(key) == true else { throw SVGAError.invalidOperation("精灵 key 不存在：\(key)") }
    }

    /// 只保留复现参数和状态，不保留图片、文本大对象或 GPU 引用。
    private func appendContent(_ id: UUID, installation: UUID?, key: String, operation: SVGAContentOperation,
                               status: SVGAContentStatus, started: Double, detail: String? = nil) {
        recordedContentEvents.append(SVGAContentEvent(requestID: id, installationID: installation, key: key,
            operation: operation, status: status, monotonicTime: Monotonic.now,
            durationSeconds: Monotonic.now - started, detail: detail))
        if recordedContentEvents.count > 256 { recordedContentEvents.removeFirst(recordedContentEvents.count - 256) }
    }
}

/// 动态准备任务的纯值输入，不包含平台视图。
private enum ContentInput: Sendable {
    /// 需要解码的图片编码数据。
    case image(Data)
    /// 文本描述和目标逻辑尺寸。
    case text(SVGAText, CGSize)
}

/// 初始化完成后只读的纹理交接；unchecked 仅覆盖 SDK 未标记 Sendable 的 MTLTexture。
struct PreparedContent: @unchecked Sendable {
    /// 可安装到唯一目标播放器的纹理，发布后不再修改像素。
    let texture: any MTLTexture
}
