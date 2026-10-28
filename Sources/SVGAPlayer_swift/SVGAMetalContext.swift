import Foundation
import Metal
import simd

/// 共享且初始化后只读的设备、队列和管线；SDK 对象本身未声明 Sendable。
/// unchecked 的边界仅覆盖 Metal 线程安全创建/提交 API；编码器不存放于此，也不跨任务共享。
final class MetalContext: @unchecked Sendable {
    /// 设备初始化失败也缓存为结果，避免每个列表行重复编译失败的 shader。
    static let shared: Result<MetalContext, Error> = Result { try MetalContext() }
    /// 所有宿主使用同一默认 Metal 设备。
    let device: any MTLDevice
    /// 线程安全命令队列，每次提交创建独立命令缓冲。
    let queue: any MTLCommandQueue
    /// 预乘 alpha 合成管线，直接输出到 drawable 或局部遮罩目标。
    let paint: any MTLRenderPipelineState
    /// 只更新 stencil、不写颜色的几何管线。
    let stencil: any MTLRenderPipelineState
    /// 三角形正反面分别累加/递减 winding 的状态。
    let accumulate: any MTLDepthStencilState
    /// winding 非零处绘制颜色，同时清零该区域的 stencil。
    let cover: any MTLDepthStencilState
    /// 普通位图合成，不读写 stencil。
    let unrestricted: any MTLDepthStencilState
    /// 用于无纹理内容和缺省遮罩的单像素白纹理。
    let white: any MTLTexture

    /// 创建一次共享管线；失败以库资源错误向安装调用者返回。
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SVGAError.resource("此设备无法创建 Metal 队列")
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        paint = try Self.pipeline(device, library: library, writesColor: true)
        stencil = try Self.pipeline(device, library: library, writesColor: false)
        let winding = MTLDepthStencilDescriptor()
        let front = MTLStencilDescriptor()
        front.stencilCompareFunction = .always
        front.depthStencilPassOperation = .incrementWrap
        let back = MTLStencilDescriptor()
        back.stencilCompareFunction = .always
        back.depthStencilPassOperation = .decrementWrap
        winding.frontFaceStencil = front
        winding.backFaceStencil = back
        let covered = MTLDepthStencilDescriptor()
        let test = MTLStencilDescriptor()
        test.stencilCompareFunction = .notEqual
        test.depthStencilPassOperation = .zero
        covered.frontFaceStencil = test
        covered.backFaceStencil = test
        guard let accumulate = device.makeDepthStencilState(descriptor: winding),
              let cover = device.makeDepthStencilState(descriptor: covered),
              let unrestricted = device.makeDepthStencilState(descriptor: MTLDepthStencilDescriptor()) else {
            throw SVGAError.resource("Metal stencil 状态创建失败")
        }
        self.accumulate = accumulate
        self.cover = cover
        self.unrestricted = unrestricted
        white = try MetalMovie.texture(RasterImage(width: 1, height: 1, pixels: Data([255, 255, 255, 255])), device: device)
    }

    /// 配置预乘透明合成；颜色和 stencil 共用同一顶点变换，避免遮罩错位。
    private static func pipeline(_ device: any MTLDevice, library: any MTLLibrary,
                                 writesColor: Bool) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "svgaVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "svgaFragment")
        descriptor.stencilAttachmentPixelFormat = .stencil8
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.writeMask = writesColor ? .all : []
        color.isBlendingEnabled = writesColor
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// 内嵌 Metal 程序使 SPM 在两平台上使用同一实现；只在共享设备初始化时编译。
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    /// 与 Swift MetalUniforms 保持相同字段顺序和对齐。
    struct Uniforms {
        /// 当前源几何到显示目标 NDC 的变换。
        float4x4 transform;
        /// 预乘透明度的颜色或图片乘数。
        float4 color;
        /// 归一化纹理坐标所使用的源矩形。
        float4 textureRect;
        /// 遮罩所在目标的物理像素大小。
        float2 targetSize;
        /// 仅 1 表示采样图片，0 表示纯色。
        uint useTexture;
        /// 同时参与的局部与父级遮罩数量，最多两个。
        uint maskCount;
    };
    /// 顶点插值结果；position 进入 fragment 时为目标像素坐标。
    struct VertexOutput {
        /// 光栅化前为裁剪坐标，片元入口为目标像素坐标。
        float4 position [[position]];
        /// 图片归一化坐标，透明边界由纹理 alpha 决定。
        float2 uv;
    };
    /// 将缓存的源顶点直接映射到显示目标，CPU 不做整帧像素合成。
    vertex VertexOutput svgaVertex(uint id [[vertex_id]],
        const device float2 *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        VertexOutput result;
        float2 point = vertices[id];
        result.position = u.transform * float4(point, 0, 1);
        result.uv = (point - u.textureRect.xy) / max(u.textureRect.zw, float2(0.00001));
        return result;
    }
    /// 图片与局部 GPU 遮罩均采用预乘 alpha；不做 CPU readback。
    fragment float4 svgaFragment(VertexOutput in [[stage_in]], constant Uniforms &u [[buffer(1)]],
        texture2d<float> image [[texture(0)]], texture2d<float> mask [[texture(1)]],
        texture2d<float> secondMask [[texture(2)]]) {
        constexpr sampler sampling(filter::linear, address::clamp_to_edge);
        float4 color = u.useTexture != 0 ? image.sample(sampling, in.uv) * u.color : u.color;
        float2 maskUV = in.position.xy / u.targetSize;
        if (u.maskCount > 0) color *= mask.sample(sampling, maskUV).a;
        if (u.maskCount > 1) color *= secondMask.sample(sampling, maskUV).a;
        return color;
    }
    """
}

/// 与 Metal Uniforms 精确对齐的单次绘制标量输入；不持有纹理。
struct MetalUniforms {
    /// 局部到 NDC 的矩阵。
    var transform: simd_float4x4
    /// 已预乘透明度的颜色或图片整体透明度乘数。
    var color: SIMD4<Float>
    /// 用于位图 UV 的源矩形；纯矢量时只需非零尺寸。
    var textureRect: SIMD4<Float>
    /// 目标像素大小，用于遮罩采样。
    var targetSize: SIMD2<Float>
    /// 1 表示采样图片，0 表示使用纯色。
    var useTexture: UInt32
    /// 参与合成的屏幕空间遮罩数，范围 0...2。
    var maskCount: UInt32
}
