import Foundation
import CryptoKit

/// 可取消的影片加载器与有界内容缓存；默认 nonisolated 包中独立的解析 actor。
public actor SVGALoader {
    /// 进程共享的默认加载器；调用方也可创建独立预算实例。
    public static let shared = SVGALoader()
    /// 累计缓存统计及当前留存；计费不是进程 RSS。
    public private(set) var statistics: SVGACacheStatistics
    /// SHA-256 到已完成影片的映射。
    private var cached: [String: SVGAMovie] = [:]
    /// 最久未访问到最近访问的缓存 key 顺序。
    private var recency: [String] = []
    /// 可共享的内容摘要到当前解析身份；失效后旧身份不能回写缓存。
    private var current: [String: UUID] = [:]
    /// 所有在途解析，包括已失效但尚未响应取消的任务。
    private var flights: [UUID: Flight] = [:]
    /// 后台解析入口；内部注入只用于确定性验证共享和失效竞争，公开入口始终使用真实解码器。
    private let decode: @Sendable (Data, String) async throws -> SVGAMovie

    /// 创建独立解析缓存；负预算视为零，零预算仍允许在途共享。
    public init(byteLimit: Int = 128 * 1024 * 1024) {
        statistics = SVGACacheStatistics(byteLimit: max(0, byteLimit))
        decode = { try SVGADecoder.decode($0, identity: $1) }
    }

    /// 测试可控制真实解析开始/完成之间的暂停点，不对外暴露自定义文件语义。
    init(byteLimit: Int, decode: @escaping @Sendable (Data, String) async throws -> SVGAMovie) {
        statistics = SVGACacheStatistics(byteLimit: max(0, byteLimit))
        self.decode = decode
    }

    /// 从本地或 HTTP(S) URL 加载；成功和失败均携带本请求报告。
    /// 取消某个等待者不会取消其他等待者，最后一人离开时终止解析。
    public func load(from url: URL, policy: SVGALoadPolicy = .useCache) async throws -> SVGALoadResult {
        let started = Monotonic.now
        let requestID = UUID()
        var report = SVGALoadReport(requestID: requestID,
                                    sourcePath: url.isFileURL ? url.path : url.absoluteString, policy: policy)
        var phaseStarted = started
        do {
            try Task.checkCancellation()
            let data: Data
            do { data = try await Self.read(url) }
            catch { report.readSeconds = Monotonic.now - phaseStarted; throw error }
            report.readSeconds = Monotonic.now - phaseStarted
            report.sourceBytes = data.count
            phaseStarted = Monotonic.now
            let identity: String
            do { identity = try await Self.digest(data) }
            catch { report.digestSeconds = Monotonic.now - phaseStarted; throw error }
            report.digestSeconds = Monotonic.now - phaseStarted
            report.sha256 = identity
            try Task.checkCancellation()
            if policy == .reload { invalidate(identity) }
            if policy == .useCache, let movie = cached[identity] {
                statistics.hits += 1
                touch(identity)
                report.cachePath = .hit
                report.status = .succeeded
                report.totalSeconds = Monotonic.now - started
                return SVGALoadResult(movie: movie, report: report)
            }
            let id: UUID
            if policy == .useCache, let existing = current[identity] {
                id = existing
                report.cachePath = .joined
                statistics.shared += 1
            } else {
                id = UUID()
                report.cachePath = policy == .bypassCache ? .bypassed : .miss
                if policy != .bypassCache { statistics.misses += 1 }
                start(data, identity: identity, id: id, cacheable: policy != .bypassCache)
            }
            phaseStarted = Monotonic.now
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    // onCancel 的 actor 跳转可能先到达；注册时再次检查，确保 continuation 必定结束。
                    if Task.isCancelled {
                        continuation.resume(returning: ParseOutcome(result: .failure(CancellationError()), seconds: nil))
                        cancelEmptyFlight(id)
                    } else if var flight = flights[id] {
                        flight.waiters[requestID] = continuation
                        flights[id] = flight
                    } else {
                        continuation.resume(returning: ParseOutcome(result: .failure(CancellationError()), seconds: nil))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(requestID, flightID: id) }
            }
            if report.cachePath == .joined { report.sharedWaitSeconds = Monotonic.now - phaseStarted }
            else { report.parseSeconds = outcome.seconds }
            try Task.checkCancellation()
            let movie = try outcome.result.get()
            report.status = .succeeded
            report.totalSeconds = Monotonic.now - started
            return SVGALoadResult(movie: movie, report: report)
        } catch {
            if error is CancellationError || Task.isCancelled {
                report.status = .cancelled
                statistics.cancellations += 1
            } else {
                report.status = .failed
                report.error = String(describing: error)
                statistics.failures += 1
            }
            report.totalSeconds = Monotonic.now - started
            throw SVGALoadFailure(report: report)
        }
    }

    /// 清空已完成缓存并使当前代失效；已有调用者仍可收到结果，但迟到结果不能重新填满缓存。
    public func clearCache() {
        statistics.invalidations += cached.count + current.count
        cached.removeAll()
        recency.removeAll()
        current.removeAll()
        updateRetained()
    }

    /// 仅使指定内容的旧代失效，供强制重载使用；不撤销其他调用者的读取。
    private func invalidate(_ identity: String) {
        if cached.removeValue(forKey: identity) != nil { statistics.invalidations += 1 }
        if current.removeValue(forKey: identity) != nil { statistics.invalidations += 1 }
        recency.removeAll { $0 == identity }
        updateRetained()
    }

    /// 后台解析不占用 actor 执行器；完成时仅向 actor 传递不可变值和耗时。
    private func start(_ data: Data, identity: String, id: UUID, cacheable: Bool) {
        statistics.parses += 1
        statistics.inFlight += 1
        if cacheable { current[identity] = id }
        let decode = decode
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let started = Monotonic.now
            let result: Result<SVGAMovie, Error>
            do { result = .success(try await decode(data, identity)) }
            catch { result = .failure(error) }
            await self?.complete(id, outcome: ParseOutcome(result: result, seconds: Monotonic.now - started))
        }
        flights[id] = Flight(identity: identity, cacheable: cacheable, task: task)
    }

    /// 回写前核对解析身份；失效、无等待者或超预算的结果不会进入缓存。
    private func complete(_ id: UUID, outcome: ParseOutcome) {
        guard let flight = flights.removeValue(forKey: id) else { return }
        statistics.inFlight -= 1
        let isCurrent = current[flight.identity] == id
        if isCurrent { current.removeValue(forKey: flight.identity) }
        if flight.cacheable && !isCurrent { statistics.discardedResults += 1 }
        if isCurrent, !flight.waiters.isEmpty, case .success(let movie) = outcome.result,
           movie.accountedBytes <= statistics.byteLimit {
            cached[flight.identity] = movie
            touch(flight.identity)
            updateRetained()
            while statistics.retainedBytes > statistics.byteLimit, let oldest = recency.first {
                recency.removeFirst()
                cached.removeValue(forKey: oldest)
                statistics.evictions += 1
                updateRetained()
            }
        }
        for waiter in flight.waiters.values { waiter.resume(returning: outcome) }
    }

    /// 结束一个调用者的等待，其他调用者保留共享工作。
    private func cancelWaiter(_ requestID: UUID, flightID: UUID) {
        guard var flight = flights[flightID], let waiter = flight.waiters.removeValue(forKey: requestID) else { return }
        flights[flightID] = flight
        waiter.resume(returning: ParseOutcome(result: .failure(CancellationError()), seconds: nil))
        cancelEmptyFlight(flightID)
    }

    /// 最后一个等待者离开后撤销后台工作，并先移除共享入口，避免新请求加入已取消任务。
    private func cancelEmptyFlight(_ id: UUID) {
        guard let flight = flights[id], flight.waiters.isEmpty else { return }
        if current[flight.identity] == id { current.removeValue(forKey: flight.identity) }
        flight.task.cancel()
    }

    /// 更新访问顺序；缓存规模按影片数有界，简单数组便于保持确定淘汰顺序。
    private func touch(_ identity: String) {
        recency.removeAll { $0 == identity }
        recency.append(identity)
    }

    /// 从实际字典重新计算占用，避免取消或失效分支造成计数漂移。
    private func updateRetained() {
        statistics.retainedMovies = cached.count
        statistics.retainedBytes = cached.values.reduce(0) { $0 + $1.accountedBytes }
    }

    /// 分块读取本地文件，网络由 URLSession 的取消传播负责；读取总量受同一输入预算限制。
    @concurrent private static func read(_ url: URL) async throws -> Data {
        if url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard let block = try handle.read(upToCount: 64 * 1024), !block.isEmpty else { return data }
                guard block.count <= SVGAContainer.byteLimit - data.count else { throw SVGAError.invalidData("输入超过上限") }
                data.append(block)
            }
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw SVGAError.unsupported("URL scheme") }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SVGAError.resource("HTTP 响应失败")
        }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 65_536) { try Task.checkCancellation() }
            guard data.count < SVGAContainer.byteLimit else { throw SVGAError.invalidData("输入超过上限") }
            data.append(byte)
        }
        return data
    }

    /// 分块计算内容摘要，避免大文件摘要阶段无法取消。
    @concurrent private static func digest(_ data: Data) async throws -> String {
        var hasher = SHA256()
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            try Task.checkCancellation()
            hasher.update(data: data[offset..<min(data.count, offset + 65_536)])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 在途任务的 actor 私有拥有关系；每个 continuation 只由取消或完成之一恢复。
private struct Flight {
    /// 对应原始内容摘要。
    let identity: String
    /// 绕过缓存的任务不会登记共享入口。
    let cacheable: Bool
    /// 实际后台工作，最后一人离开时取消。
    let task: Task<Void, Never>
    /// 当前还在等待的调用者，key 是请求身份。
    var waiters: [UUID: CheckedContinuation<ParseOutcome, Never>] = [:]
}

/// 后台解析的一次终结消息，不携带平台资源。
private struct ParseOutcome: Sendable {
    /// 完整影片或原始错误，绝不返回部分模型。
    let result: Result<SVGAMovie, Error>
    /// 后台任务实际耗时；调用者提前取消时尚未观测，为 nil。
    let seconds: Double?
}
