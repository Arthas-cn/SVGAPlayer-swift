import Foundation
import zlib

/// 只负责 ZIP/zlib 容器解包；输出内存字节，不写临时文件，也不解释影片字段。
/// 分流与条目名来自旧 Source/SVGAParser.m 的 isZIPData、parseWithData 和 parseWithCacheKey。
enum SVGAContainer {
    /// 限制解压总量为 256 MiB，避免损坏输入无限扩张；不是播放纹理预算。
    static let byteLimit = 256 * 1024 * 1024

    /// 返回影片载荷、是否为 JSON 以及包内附件；取消与损坏均向调用者抛出。
    static func unpack(_ data: Data) throws -> (payload: Data, json: Bool, assets: [String: Data]) {
        try Task.checkCancellation()
        guard data.count >= 4, data.count <= byteLimit else { throw SVGAError.invalidData("容器长度") }
        if data.starts(with: [0x50, 0x4b]) {
            let assets = try unzip(data)
            // 与旧解析器一致，ZIP 同时有两种载荷时优先 movie.binary。
            if let binary = assets["movie.binary"] { return (binary, false, assets) }
            if let json = assets["movie.spec"] { return (json, true, assets) }
            throw SVGAError.invalidData("ZIP 缺少 movie.binary/movie.spec")
        }
        return (try inflate(data, raw: false), false, [:])
    }

    /// 分块调用系统 zlib；每个输出块检查取消和上限，并验证完整流结束。
    static func inflate(_ data: Data, raw: Bool, limit: Int = byteLimit) throws -> Data {
        var stream = z_stream()
        // ZIP 使用无 zlib 头的 raw DEFLATE；整段 SVGA 则对应旧 zlibInflate 的默认窗口。
        guard inflateInit2_(&stream, raw ? -MAX_WBITS : MAX_WBITS, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SVGAError.resource("zlib 初始化失败")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard count <= limit - output.count else { throw SVGAError.invalidData("解压超过上限") }
                output.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw SVGAError.invalidData("压缩流尾部多余数据") }
                    return output
                }
                // 未结束且无法继续消费输入/输出时应报截断，不允许无进展循环。
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else {
                    throw SVGAError.invalidData("压缩流损坏或截断：\(status)")
                }
            }
        }
    }

    /// 按 PKWARE APPNOTE 6.3.10 §4.3.7/4.3.12/4.3.16 读取标准单卷 ZIP。
    /// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT；ZIP64/加密明确失败。
    private static func unzip(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw SVGAError.invalidData("ZIP 尾部截断") }
        var end: Int?
        // EOCD 的注释最多 UInt16.max 字节，签名还需通过注释长度校验以免匹配注释正文。
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try integer(bytes, offset, 4) == 0x06054b50,
               try offset + 22 + integer(bytes, offset + 20, 2) == bytes.count {
                end = offset
                break
            }
        }
        guard let end else { throw SVGAError.invalidData("ZIP 缺少 EOCD") }
        let entries = try integer(bytes, end + 10, 2)
        let size = try integer(bytes, end + 12, 4)
        var cursor = try integer(bytes, end + 16, 4)
        guard try integer(bytes, end + 4, 2) == 0,
              try integer(bytes, end + 6, 2) == 0,
              try integer(bytes, end + 8, 2) == entries,
              entries != 65_535, size != 0xffff_ffff, cursor != 0xffff_ffff else {
            throw SVGAError.unsupported("多卷 ZIP 或 ZIP64")
        }
        guard cursor <= end, size == end - cursor else { throw SVGAError.invalidData("ZIP 中央目录范围") }
        var result: [String: Data] = [:]
        var expanded = 0
        for _ in 0..<entries {
            try Task.checkCancellation()
            guard try integer(bytes, cursor, 4) == 0x02014b50 else { throw SVGAError.invalidData("ZIP 中央目录签名") }
            let flags = try integer(bytes, cursor + 8, 2)
            let method = try integer(bytes, cursor + 10, 2)
            let crc = try integer(bytes, cursor + 16, 4)
            let compressed = try integer(bytes, cursor + 20, 4)
            let uncompressed = try integer(bytes, cursor + 24, 4)
            let nameLength = try integer(bytes, cursor + 28, 2)
            let extraLength = try integer(bytes, cursor + 30, 2)
            let commentLength = try integer(bytes, cursor + 32, 2)
            let local = try integer(bytes, cursor + 42, 4)
            guard flags & 0x2041 == 0, method == 0 || method == 8,
                  try integer(bytes, cursor + 34, 2) == 0,
                  compressed != 0xffff_ffff, uncompressed != 0xffff_ffff, local != 0xffff_ffff else {
                throw SVGAError.unsupported("ZIP 加密、压缩算法或 ZIP64")
            }
            let nameData = try slice(bytes, cursor + 46, nameLength)
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains("..") else {
                throw SVGAError.invalidData("ZIP 条目路径")
            }
            cursor += 46 + nameLength + extraLength + commentLength
            guard cursor <= end, uncompressed <= byteLimit - expanded else {
                throw SVGAError.invalidData("ZIP 目录或解压总量超过上限")
            }
            guard try integer(bytes, local, 4) == 0x04034b50,
                  try integer(bytes, local + 6, 2) == flags,
                  try integer(bytes, local + 8, 2) == method else {
                throw SVGAError.invalidData("ZIP 本地头与中央目录不一致")
            }
            let localNameLength = try integer(bytes, local + 26, 2)
            let localExtraLength = try integer(bytes, local + 28, 2)
            guard try slice(bytes, local + 30, localNameLength) == nameData else {
                throw SVGAError.invalidData("ZIP 条目名称不一致")
            }
            let payloadOffset = local + 30 + localNameLength + localExtraLength
            guard payloadOffset <= end - size, compressed <= end - size - payloadOffset else {
                throw SVGAError.invalidData("ZIP 载荷越过中央目录")
            }
            let payload = try slice(bytes, payloadOffset, compressed)
            // 中央目录提供最终尺寸，因此兼容 bit 3 的 data descriptor，不猜本地头中的占位值。
            let value = try method == 0 ? payload : inflate(payload, raw: true, limit: uncompressed)
            guard value.count == uncompressed else { throw SVGAError.invalidData("ZIP 解压长度不符") }
            let actualCRC = value.withUnsafeBytes { buffer in
                crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            }
            guard actualCRC == crc else { throw SVGAError.invalidData("ZIP CRC 不符") }
            expanded += value.count
            if name.hasSuffix("/") { continue } // 目录仅用于组织附件，不产生资源数据。
            guard result[name] == nil else { throw SVGAError.invalidData("ZIP 重复条目：\(name)") }
            result[name] = value
        }
        guard cursor == end else { throw SVGAError.invalidData("ZIP 中央目录条目数不符") }
        return result
    }

    /// 安全读取小端整数，先验证范围，杜绝损坏输入导致下标崩溃。
    private static func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) throws -> Int {
        guard offset >= 0, offset <= bytes.count, count <= bytes.count - offset else {
            throw SVGAError.invalidData("ZIP 字段越界")
        }
        return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
    }

    /// 拷贝已验证范围的字段或压缩载荷；不返回指向临时缓冲的指针。
    private static func slice(_ bytes: [UInt8], _ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, offset <= bytes.count, count <= bytes.count - offset else {
            throw SVGAError.invalidData("ZIP 数据越界")
        }
        return Data(bytes[offset..<(offset + count)])
    }
}
