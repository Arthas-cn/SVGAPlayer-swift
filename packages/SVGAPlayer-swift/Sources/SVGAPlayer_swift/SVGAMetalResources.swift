import Foundation
import Metal
import CoreGraphics

/// 已上传的只读轮廓缓冲；写入仅发生在初始化，之后可跨任务只读共享。
/// unchecked 仅覆盖 SDK 未标 Sendable 的 MTLBuffer，所有 buffer 内容在发布前写完。
struct MetalPath: @unchecked Sendable {
    /// 准备后的三角扇顶点；空路径为 nil。
    let buffer: (any MTLBuffer)?
    /// 有方向三角形的顶点数量。
    let vertexCount: Int
    /// 源坐标包围盒。
    let bounds: CGRect
}

/// 单种颜色的 GPU 矢量输入。
struct MetalShape: Sendable {
    /// 已上传轮廓，播放时不再细分。
    let path: MetalPath
    /// 源 RGBA 色值，提交时再乘精灵透明度。
    let color: SVGAColor
}

/// 完成一次安装准备的不可变 GPU 输入；Metal 资源由设备创建，提交期间不修改内容。
/// unchecked 仅覆盖只读 MTLTexture，资源发布后不再 replace 或作为 render target。
struct MetalMovie: @unchecked Sendable {
    /// 共享源模型，包含帧求值所需的布局与变换。
    let movie: SVGAMovie
    /// 每个源位图只解码并上传一次。
    let images: [String: any MTLTexture]
    /// 按形状值去重的填充/描边几何。
    let shapes: [MovieShape: [MetalShape]]
    /// 按路径字符串去重的裁切几何。
    let clips: [String: MetalPath]
    /// GPU 输入纹理和缓冲的计费字节，不是进程内存。
    let accountedBytes: Int

    /// 在后台准备全部图片及真正出现的几何；取消后不向播放器安装部分结果。
    @concurrent static func prepare(_ movie: SVGAMovie, context: MetalContext) async throws -> MetalMovie {
        let device = context.device
        var images: [String: any MTLTexture] = [:]
        var shapes: [MovieShape: [MetalShape]] = [:]
        var clips: [String: MetalPath] = [:]
        var bytes = 0
        for (key, data) in movie.images {
            try Task.checkCancellation()
            let image = try SVGARasterizer.image(data)
            let texture = try texture(image, device: device)
            images[key] = texture
            bytes += image.pixels.count
            guard bytes <= 512 * 1024 * 1024 else { throw SVGAError.resource("单影片 GPU 输入超过 512 MiB") }
        }
        for sprite in movie.sprites {
            for frame in sprite.frames {
                try Task.checkCancellation()
                for shape in frame.shapes where shapes[shape] == nil {
                    shapes[shape] = try SVGAGeometry.prepare(shape).map { geometry in
                        bytes += geometry.path.triangles.count * MemoryLayout<SIMD2<Float>>.stride
                        return MetalShape(path: try upload(geometry.path, device: device), color: geometry.color)
                    }
                }
                if !frame.clipPath.isEmpty, clips[frame.clipPath] == nil {
                    let path = try SVGAGeometry.clip(frame.clipPath)
                    clips[frame.clipPath] = try upload(path, device: device)
                    bytes += path.triangles.count * MemoryLayout<SIMD2<Float>>.stride
                }
                guard bytes <= 512 * 1024 * 1024 else { throw SVGAError.resource("单影片 GPU 输入超过 512 MiB") }
            }
        }
        return MetalMovie(movie: movie, images: images, shapes: shapes, clips: clips, accountedBytes: bytes)
    }

    /// 上传预乘 RGBA8，CPU 数据随后可以释放；纹理不作为 CPU 读回目标。
    static func texture(_ image: RasterImage, device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SVGAError.resource("图片纹理分配失败") }
        image.pixels.withUnsafeBytes { data in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: data.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }

    /// 将路径三角扇一次上传，空轮廓保留空值以便绘制层快速跳过。
    private static func upload(_ geometry: PathGeometry, device: any MTLDevice) throws -> MetalPath {
        if geometry.triangles.isEmpty { return MetalPath(buffer: nil, vertexCount: 0, bounds: geometry.bounds) }
        let buffer = geometry.triangles.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let buffer else { throw SVGAError.resource("矢量缓冲分配失败") }
        return MetalPath(buffer: buffer, vertexCount: geometry.triangles.count, bounds: geometry.bounds)
    }
}
