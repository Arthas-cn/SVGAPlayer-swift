import Foundation
import CoreGraphics
import Metal
import simd

/// 已安装的精灵覆盖值；纹理发布后只读，因此可跨准备任务传送。
struct MetalContent: @unchecked Sendable {
    /// 替换图片或文本纹理；nil 表示继续使用源内容。
    var texture: (any MTLTexture)?
    /// true 时跳过该 key 的全部内容。
    var hidden = false
}

/// 单次编码结果；commandBuffer 只由播放器提交一次，不跨调用重用编码器。
struct MetalSubmission: @unchecked Sendable {
    /// 已编码、尚未提交的命令缓冲。
    let commandBuffer: any MTLCommandBuffer
    /// 实际 setBytes 的动态输入总量。
    let cpuInputBytes: Int
    /// 当前辅助纹理留存，不含输入纹理或 drawable。
    let auxiliaryBytes: Int
}

/// 播放器 actor 独占的 Metal 编码器拥有者；最终合成直接写 drawable。
/// 仅局部 clip/matte 需要 GPU 附件；无整帧 CPU 合成、读回或末端拷贝。
final class MetalRenderer {
    /// 只读共享设备和管线。
    private let context: MetalContext
    /// 当前目标尺寸对应的 stencil，所有 pass 按命令缓冲顺序复用。
    private var stencil: (any MTLTexture)?
    /// 按用途复用的局部遮罩/组纹理；尺寸或安装变化时释放。
    private var attachments: [String: any MTLTexture] = [:]
    /// 辅助纹理当前像素尺寸。
    private var targetSize = SIMD2<Int>.zero
    /// 本次编码实际动态 CPU 输入量。
    private var cpuBytes = 0
    /// 源画布映射到显示目标后的裁切范围；nil 用于整目标清屏。
    private var canvasScissor: MTLScissorRect?

    /// 创建独占渲染状态；共享管线不在每个会话重新编译。
    init(context: MetalContext) { self.context = context }

    /// 编码一帧到目标，内部错误向主播放失败传播；返回后由调用者注册回调并提交。
    func encode(scene: MetalMovie?, frame: Int, target: any MTLTexture, mode: SVGADisplayMode,
                scale: Double, content: [String: MetalContent]) throws -> MetalSubmission {
        try resize(width: target.width, height: target.height)
        cpuBytes = 0
        canvasScissor = nil
        guard let command = context.queue.makeCommandBuffer() else { throw SVGAError.resource("命令缓冲创建失败") }
        guard let scene else {
            let encoder = try encoder(command, target: target, clear: true)
            encoder.endEncoding()
            return MetalSubmission(commandBuffer: command, cpuInputBytes: 0, auxiliaryBytes: auxiliaryBytes)
        }
        let movie = scene.movie
        let mapping = projection(movie: movie.size, target: CGSize(width: target.width, height: target.height),
                                 mode: mode, scale: scale)
        // SVGAPlayer.draw 的根 drawLayer.masksToBounds 为 true；宽屏适配也不能泄漏源画布外精灵。
        let topLeft = mapping * SIMD4<Float>(0, 0, 0, 1)
        let bottomRight = mapping * SIMD4<Float>(Float(movie.size.width), Float(movie.size.height), 0, 1)
        let left = max(0, Int(floor(Double(topLeft.x + 1) * Double(target.width) / 2)))
        let top = max(0, Int(floor(Double(1 - topLeft.y) * Double(target.height) / 2)))
        let right = min(target.width, Int(ceil(Double(bottomRight.x + 1) * Double(target.width) / 2)))
        let bottom = min(target.height, Int(ceil(Double(1 - bottomRight.y) * Double(target.height) / 2)))
        canvasScissor = MTLScissorRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        var clips: [Int: any MTLTexture] = [:]
        for (index, sprite) in movie.sprites.enumerated() {
            guard let state = state(sprite, at: frame), !state.clipPath.isEmpty,
                  let geometry = scene.clips[state.clipPath], content[sprite.key]?.hidden != true else { continue }
            let texture = try attachment("clip-\(index)")
            let encoder = try encoder(command, target: texture, clear: true)
            drawPath(geometry, color: SVGAColor(red: 1, green: 1, blue: 1), alpha: 1,
                     transform: transform(state, mapping: mapping), masks: [], encoder: encoder)
            encoder.endEncoding()
            clips[index] = texture
        }
        var masks: [String: any MTLTexture] = [:]
        var visiting = Set<String>()
        // 所有 matte 先准备；同一帧多个受遮罩组共享同一个 mask，不重复绘制。
        for sprite in movie.sprites {
            if let key = sprite.matteKey {
                try prepareMask(key, scene: scene, frame: frame, mapping: mapping, content: content,
                                clips: clips, masks: &masks, visiting: &visiting, command: command)
            }
        }
        var main = try encoder(command, target: target, clear: true)
        var index = 0
        while index < movie.sprites.count {
            let sprite = movie.sprites[index]
            if sprite.key.hasSuffix(".matte") { index += 1; continue } // 遮罩精灵不直接出现在最终画面。
            if let key = sprite.matteKey {
                main.endEncoding()
                let group = try attachment("group")
                let groupEncoder = try encoder(command, target: group, clear: true)
                // 与旧 SVGAPlayer.draw 的连续 matteKey 组一致：先组内合成，再乘一次遮罩 alpha。
                repeat {
                    drawSprite(index, scene: scene, frame: frame, mapping: mapping, content: content,
                               masks: clips[index].map { [$0] } ?? [], encoder: groupEncoder)
                    index += 1
                } while index < movie.sprites.count && movie.sprites[index].matteKey == key
                groupEncoder.endEncoding()
                main = try encoder(command, target: target, clear: false)
                let box = CGRect(x: 0, y: 0, width: target.width, height: target.height)
                drawQuad(box, texture: group, color: SIMD4(repeating: 1),
                         transform: screenProjection(), masks: masks[key].map { [$0] } ?? [], encoder: main)
            } else {
                drawSprite(index, scene: scene, frame: frame, mapping: mapping, content: content,
                           masks: clips[index].map { [$0] } ?? [], encoder: main)
                index += 1
            }
        }
        main.endEncoding()
        return MetalSubmission(commandBuffer: command, cpuInputBytes: cpuBytes, auxiliaryBytes: auxiliaryBytes)
    }

    /// 当前附件的保守字节计费，不把 drawable 或进程 RSS 算入输入缓存。
    private var auxiliaryBytes: Int {
        targetSize.x * targetSize.y * (attachments.count * 4 + (stencil == nil ? 0 : 1))
    }

    /// 支持 matte 引用链，同时检测循环；引用不存在已在解析层报错。
    private func prepareMask(_ key: String, scene: MetalMovie, frame: Int, mapping: simd_float4x4,
                             content: [String: MetalContent], clips: [Int: any MTLTexture],
                             masks: inout [String: any MTLTexture], visiting: inout Set<String>,
                             command: any MTLCommandBuffer) throws {
        if masks[key] != nil { return }
        guard visiting.insert(key).inserted,
              let index = scene.movie.sprites.lastIndex(where: { $0.key == key }) else {
            throw SVGAError.invalidData("循环或缺失 matte：\(key)")
        }
        defer { visiting.remove(key) }
        var inputs = clips[index].map { [$0] } ?? []
        if let parent = scene.movie.sprites[index].matteKey {
            try prepareMask(parent, scene: scene, frame: frame, mapping: mapping, content: content,
                            clips: clips, masks: &masks, visiting: &visiting, command: command)
            if let mask = masks[parent] { inputs.append(mask) }
        }
        let texture = try attachment("matte-\(key)")
        let encoder = try encoder(command, target: texture, clear: true)
        drawSprite(index, scene: scene, frame: frame, mapping: mapping, content: content,
                   masks: inputs, encoder: encoder)
        encoder.endEncoding()
        masks[key] = texture
    }

    /// 求值源帧并绘制位图和缓存矢量；动态替换纹理覆盖整个精灵内容。
    private func drawSprite(_ index: Int, scene: MetalMovie, frame: Int, mapping: simd_float4x4,
                            content: [String: MetalContent], masks: [any MTLTexture], encoder: any MTLRenderCommandEncoder) {
        let sprite = scene.movie.sprites[index]
        guard content[sprite.key]?.hidden != true, let state = state(sprite, at: frame), state.alpha > 0 else { return }
        let transform = transform(state, mapping: mapping)
        let localBox = CGRect(origin: .zero, size: state.layout.cgRect.size)
        let replacement = content[sprite.key]?.texture
        // 旧 SVGAPlayer.draw 对 bitmapKey 去后缀；原文 key 仍用于公开替换目录。
        let texture = replacement ?? scene.images[(sprite.key as NSString).deletingPathExtension] ?? scene.images[sprite.key]
        if let texture, localBox.width > 0, localBox.height > 0 {
            drawQuad(localBox, texture: texture, color: SIMD4(repeating: Float(state.alpha)),
                     transform: transform, masks: masks, encoder: encoder)
        }
        if replacement != nil { return } // 新 API 的内容替换不叠加源矢量，恢复时再使用源模型。
        for shape in state.shapes {
            for geometry in scene.shapes[shape] ?? [] {
                drawPath(geometry.path, color: geometry.color, alpha: state.alpha,
                         transform: transform, masks: masks, encoder: encoder)
            }
        }
    }

    /// 旧 stepToFrame 在精灵帧耗尽后保留最后状态；源多余尾帧不会超出影片时间轴访问。
    private func state(_ sprite: SVGASprite, at frame: Int) -> SpriteFrame? {
        guard !sprite.frames.isEmpty else { return nil }
        return sprite.frames[min(max(0, frame), sprite.frames.count - 1)]
    }

    /// 有方向三角扇先写 winding，再以包围盒着色并清零；凹轮廓不会被当凸多边形填满。
    private func drawPath(_ path: MetalPath, color: SVGAColor, alpha: Double,
                          transform: simd_float4x4, masks: [any MTLTexture], encoder: any MTLRenderCommandEncoder) {
        guard let buffer = path.buffer, path.vertexCount > 0, !path.bounds.isEmpty else { return }
        let opacity = Float(color.alpha * alpha)
        let rgba = SIMD4(Float(color.red) * opacity, Float(color.green) * opacity, Float(color.blue) * opacity, opacity)
        var uniforms = uniforms(transform: transform, color: rgba, rect: path.bounds, textured: false, masks: masks.count)
        bind(&uniforms, texture: nil, masks: masks, encoder: encoder)
        encoder.setRenderPipelineState(context.stencil)
        encoder.setDepthStencilState(context.accumulate)
        encoder.setStencilReferenceValue(0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: path.vertexCount)
        encoder.setRenderPipelineState(context.paint)
        encoder.setDepthStencilState(context.cover)
        vertices(path.bounds, encoder: encoder)
    }

    /// 绘制图片、替换内容或局部遮罩组到当前目标，不额外创建整帧截图。
    private func drawQuad(_ rect: CGRect, texture: any MTLTexture, color: SIMD4<Float>,
                          transform: simd_float4x4, masks: [any MTLTexture], encoder: any MTLRenderCommandEncoder) {
        var uniforms = uniforms(transform: transform, color: color, rect: rect, textured: true, masks: masks.count)
        bind(&uniforms, texture: texture, masks: masks, encoder: encoder)
        encoder.setRenderPipelineState(context.paint)
        encoder.setDepthStencilState(context.unrestricted)
        vertices(rect, encoder: encoder)
    }

    /// 统一传入顶点和 fragment 输入；计费精确覆盖本次 setBytes，不将静态几何重复计入。
    private func bind(_ uniforms: inout MetalUniforms, texture: (any MTLTexture)?,
                      masks: [any MTLTexture], encoder: any MTLRenderCommandEncoder) {
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.stride, index: 1)
        cpuBytes += MemoryLayout<MetalUniforms>.stride * 2
        encoder.setFragmentTexture(texture ?? context.white, index: 0)
        encoder.setFragmentTexture(masks.first ?? context.white, index: 1)
        encoder.setFragmentTexture(masks.count > 1 ? masks[1] : context.white, index: 2)
    }

    /// 提交六个矩形顶点，避免为每张位图永久持有重复的顶点 buffer。
    private func vertices(_ rect: CGRect, encoder: any MTLRenderCommandEncoder) {
        let x = Float(rect.minX), y = Float(rect.minY), r = Float(rect.maxX), b = Float(rect.maxY)
        let values: [SIMD2<Float>] = [SIMD2(x, y), SIMD2(r, y), SIMD2(x, b), SIMD2(r, y), SIMD2(r, b), SIMD2(x, b)]
        values.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            cpuBytes += bytes.count
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: values.count)
    }

    /// 构造与 shader 对齐的值输入。
    private func uniforms(transform: simd_float4x4, color: SIMD4<Float>, rect: CGRect,
                          textured: Bool, masks: Int) -> MetalUniforms {
        MetalUniforms(transform: transform, color: color,
            textureRect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
            targetSize: SIMD2(Float(targetSize.x), Float(targetSize.y)), useTexture: textured ? 1 : 0, maskCount: UInt32(masks))
    }

    /// 源层的局部坐标先加 layout.origin，再经源仿射矩阵和画布适配。
    private func transform(_ frame: SpriteFrame, mapping: simd_float4x4) -> simd_float4x4 {
        let t = frame.transform
        let tx = t.a * frame.layout.x + t.c * frame.layout.y + t.tx
        let ty = t.b * frame.layout.x + t.d * frame.layout.y + t.ty
        let local = simd_float4x4(columns: (SIMD4(Float(t.a), Float(t.b), 0, 0),
            SIMD4(Float(t.c), Float(t.d), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(Float(tx), Float(ty), 0, 1)))
        return mapping * local
    }

    /// 四种明确适配模式；originalSize 使用宿主内容比例把源逻辑点映射为屏幕像素。
    private func projection(movie: CGSize, target: CGSize, mode: SVGADisplayMode, scale: Double) -> simd_float4x4 {
        let fitX = target.width / movie.width, fitY = target.height / movie.height
        let sx: Double, sy: Double
        switch mode {
        case .aspectFit: sx = min(fitX, fitY); sy = sx
        case .aspectFill: sx = max(fitX, fitY); sy = sx
        case .stretch: sx = fitX; sy = fitY
        case .originalSize: sx = scale; sy = scale
        }
        let x = (target.width - movie.width * sx) / 2, y = (target.height - movie.height * sy) / 2
        let placement = simd_float4x4(columns: (SIMD4(Float(sx), 0, 0, 0), SIMD4(0, Float(sy), 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(Float(x), Float(y), 0, 1)))
        return screenProjection() * placement
    }

    /// 左上原点的像素坐标映射到 Metal NDC，所有目标都使用同一方向。
    private func screenProjection() -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(2 / Float(targetSize.x), 0, 0, 0),
            SIMD4(0, -2 / Float(targetSize.y), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-1, 1, 0, 1)))
    }

    /// 目标变大或缩小时释放旧附件，预算检查在任何分配之前执行。
    private func resize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width <= SVGARasterizer.maximumPixels / height else { throw SVGAError.resource("显示目标尺寸超过预算") }
        guard targetSize != SIMD2(width, height) else { return }
        attachments.removeAll()
        targetSize = SIMD2(width, height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .renderTarget
        stencil = context.device.makeTexture(descriptor: descriptor)
        guard stencil != nil else { throw SVGAError.resource("stencil 分配失败") }
    }

    /// 局部遮罩和遮罩组复用 GPU 纹理，不为普通未遮罩内容分配离屏颜色目标。
    private func attachment(_ key: String) throws -> any MTLTexture {
        if let existing = attachments[key] { return existing }
        guard auxiliaryBytes + targetSize.x * targetSize.y * 4 <= 256 * 1024 * 1024 else {
            throw SVGAError.resource("GPU 遮罩附件超过 256 MiB")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: targetSize.x, height: targetSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { throw SVGAError.resource("遮罩纹理分配失败") }
        attachments[key] = texture
        return texture
    }

    /// 创建一个独占编码器；主画面续写时 load 颜色，stencil 总是在每个 pass 重新清零。
    private func encoder(_ command: any MTLCommandBuffer, target: any MTLTexture, clear: Bool) throws -> any MTLRenderCommandEncoder {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.stencilAttachment.texture = stencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        pass.stencilAttachment.clearStencil = 0
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SVGAError.resource("render encoder 创建失败") }
        encoder.setCullMode(.none)
        if let canvasScissor { encoder.setScissorRect(canvasScissor) }
        return encoder
    }
}
