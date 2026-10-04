import Foundation
import UIKit
import ImageIO
import Combine

/// All mutable transfer state and delegate callbacks use one serial queue.
/// URLSession offers cacheable responses through willCacheResponse; storing them
/// ourselves at completion makes clearing atomic with respect to old transfers.
private final class PosterTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 8 * 1024 * 1024
    private final class Request: @unchecked Sendable {
        var cancelled = false
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Data, Error>?
        var data = Data()
        var cacheResponse: CachedURLResponse?
    }
    private let queue = DispatchQueue(label: "poster.transport", qos: .userInitiated)
    private let responseCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                         diskCapacity: 128 * 1024 * 1024,
                                         diskPath: "poster-http-v1")
    private var requests: [Int: Request] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = responseCache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
    }

    func download(_ url: URL, visible: Bool) async throws -> Data {
        let request = Request()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !request.cancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let task = self.session.dataTask(with: url)
                    task.priority = visible ? URLSessionTask.highPriority : URLSessionTask.lowPriority
                    request.task = task
                    request.continuation = continuation
                    self.requests[task.taskIdentifier] = request
                    task.resume()
                }
            }
        }, onCancel: {
            self.queue.async {
                request.cancelled = true
                if let task = request.task {
                    task.cancel()
                    self.complete(task, error: CancellationError())
                }
            }
        })
    }

    func clearCache() async {
        await withCheckedContinuation { continuation in
            queue.async {
                for request in Array(self.requests.values) {
                    request.cancelled = true
                    if let task = request.task {
                        task.cancel()
                        self.complete(task, error: CancellationError())
                    }
                }
                self.responseCache.removeAllCachedResponses()
                continuation.resume()
            }
        }
    }

    func cacheUsage() async -> Int64 {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Int64(self.responseCache.currentMemoryUsage + self.responseCache.currentDiskUsage))
            }
        }
    }

    private func complete(_ task: URLSessionTask, error: Error?) {
        guard let request = requests.removeValue(forKey: task.taskIdentifier) else { return }
        let continuation = request.continuation
        request.continuation = nil
        request.task = nil
        if let error = error {
            continuation?.resume(throwing: error)
        } else {
            if let cached = request.cacheResponse, let original = task.currentRequest {
                responseCache.storeCachedResponse(cached, for: original)
            }
            continuation?.resume(returning: request.data)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard requests[dataTask.taskIdentifier] != nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            complete(dataTask, error: URLError(.badServerResponse))
            return
        }
        guard response.expectedContentLength <= Int64(Self.limit) else {
            completionHandler(.cancel)
            complete(dataTask, error: URLError(.dataLengthExceedsMaximum))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let request = requests[dataTask.taskIdentifier] else { return }
        guard data.count <= Self.limit - request.data.count else {
            dataTask.cancel()
            complete(dataTask, error: URLError(.dataLengthExceedsMaximum))
            return
        }
        request.data.append(data)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        if proposedResponse.data.count <= Self.limit {
            requests[dataTask.taskIdentifier]?.cacheResponse = proposedResponse
        }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        complete(task, error: error)
    }
}

/// Main-actor invalidation only; transfers and decode remain off the UI actor.
@MainActor
final class PosterCacheState: ObservableObject {
    static let shared = PosterCacheState()
    @Published private(set) var revision: UInt64 = 0
    func invalidate() { revision &+= 1 }
}

/// Shared URL + output-pixel requests. Slots cover both transfer and ImageIO decode.
actor PosterImagePipeline {
    static let shared = PosterImagePipeline()
    private let cache = NSCache<NSString, UIImage>()
    private let transport = PosterTransport()
    private struct Job {
        let url: URL
        let pixels: Int
        var visible: Bool
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
        var task: Task<Void, Never>?
        var cancelling = false
    }
    private var jobs: [String: Job] = [:]
    private var pending: [String] = []
    private var active = 0
    private var activePrefetch = 0
    private var clearing = false
    private let pendingLimit = 128
    private let waiterLimit = 256
    private let perJobWaiterLimit = 16
    private var consumers = 0
    private let consumerLimit = 384 // Includes admission sleepers and registered waiters.
    private var cacheRevision: UInt64 = 0

    func httpCacheUsage() async -> Int64 { await transport.cacheUsage() }

    func clearCache() async {
        cacheRevision &+= 1
        clearing = true
        cache.removeAllObjects()
        for key in Array(jobs.keys) {
            guard var job = jobs[key] else { continue }
            for waiter in job.waiters.values { waiter.resume(returning: nil) }
            job.waiters.removeAll()
            if let task = job.task {
                job.cancelling = true
                jobs[key] = job
                task.cancel()
            } else { jobs.removeValue(forKey: key) }
        }
        pending.removeAll()
        await transport.clearCache()
        clearing = false
        startPending()
        await PosterCacheState.shared.invalidate()
    }

    private func canAdmit(_ key: String) -> Bool {
        let count = jobs.values.reduce(0) { $0 + $1.waiters.count }
        guard count < waiterLimit else { return false }
        if let job = jobs[key] { return job.waiters.count < perJobWaiterLimit }
        // Reserve capacity for cancelling active jobs that may need requeueing.
        return pending.count + active < pendingLimit
    }

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 160
    }

    nonisolated static func pixelBucket(_ pixels: Int) -> Int {
        ((min(2048, max(1, pixels)) + 63) / 64) * 64
    }

    func promote(url: URL, pixels: Int) {
        let key = "\(url.absoluteString)|\(Self.pixelBucket(pixels))"
        // Running work keeps its slot; only pending work changes ordering.
        if jobs[key]?.task == nil { jobs[key]?.visible = true }
        startPending()
    }

    func image(url: URL, pixels: Int, visible: Bool = true) async -> UIImage? {
        let pixels = Self.pixelBucket(pixels)
        let key = "\(url.absoluteString)|\(pixels)"
        guard !Task.isCancelled, !clearing else { return nil }
        if let image = cache.object(forKey: key as NSString) { return image }
        guard consumers < consumerLimit else { return nil }
        consumers += 1
        defer { consumers -= 1 }
        let revision = cacheRevision
        // Bounded, cancellation-aware admission delay. Never store capacity waiters
        // in an unbounded continuation queue; overload expires after two seconds.
        var attempts = 0
        while !canAdmit(key) {
            guard attempts < 40 else { return nil }
            attempts += 1
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return nil }
            guard !Task.isCancelled, revision == cacheRevision else { return nil }
            if let image = cache.object(forKey: key as NSString) { return image }
        }
        let waiter = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, revision == cacheRevision, canAdmit(key) else { continuation.resume(returning: nil); return }
                if jobs[key] != nil {
                    jobs[key]?.waiters[waiter] = continuation
                    if visible, jobs[key]?.task == nil { jobs[key]?.visible = true }
                } else {
                    jobs[key] = Job(url: url, pixels: pixels, visible: visible, waiters: [waiter: continuation])
                    pending.append(key)
                }
                startPending()
            }
        }, onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        })
    }

    private func cancel(key: String, waiter: UUID) {
        guard var job = jobs[key] else { return }
        job.waiters.removeValue(forKey: waiter)?.resume(returning: nil)
        jobs[key] = job
        if job.waiters.isEmpty {
            if let task = job.task {
                // Keep the slot until URLSession/decode actually exits.
                task.cancel()
                jobs[key]?.cancelling = true
            } else {
                jobs.removeValue(forKey: key)
                pending.removeAll { $0 == key }
            }
        }
    }

    private func startPending() {
        guard !clearing else { return }
        while active < 6, !pending.isEmpty {
            let visibleIndex = pending.firstIndex { jobs[$0]?.visible == true }
            // Reserve two slots for visible cards even during sustained prefetch.
            guard visibleIndex != nil || activePrefetch < 4 else { return }
            let key = pending.remove(at: visibleIndex ?? 0)
            guard let job = jobs[key], !job.waiters.isEmpty else { continue }
            active += 1
            if !job.visible { activePrefetch += 1 }
            let url = job.url
            let pixels = job.pixels
            let visible = job.visible
            let transport = self.transport
            jobs[key]?.task = Task.detached(priority: visible ? .userInitiated : .utility) { [self] in
                var image: UIImage?
                do {
                    let data = try await transport.download(url, visible: visible)
                    try Task.checkCancellation()
                    image = Self.downsample(data, pixels: pixels)
                    try Task.checkCancellation()
                } catch { image = nil }
                await finish(key: key, image: image)
            }
        }
    }

    private func finish(key: String, image: UIImage?) {
        guard var job = jobs.removeValue(forKey: key) else { return }
        active -= 1
        if !job.visible { activePrefetch -= 1 }
        // A card may re-enter while the last consumer's cancelled transfer exits.
        // New consumers get a fresh transfer instead of inheriting that cancellation.
        if job.cancelling, !job.waiters.isEmpty {
            job.task = nil
            job.cancelling = false
            jobs[key] = job
            pending.append(key)
            startPending()
            return
        }
        if let image = image, !job.waiters.isEmpty, let cgImage = image.cgImage {
            cache.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        }
        for continuation in job.waiters.values { continuation.resume(returning: image) }
        startPending()
    }

    private nonisolated static func downsample(_ data: Data, pixels: Int) -> UIImage? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return UIImage(cgImage: image)
        }
    }
}
