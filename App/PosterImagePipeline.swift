import Foundation
import UIKit
import ImageIO
import Combine

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
    private struct Job {
        let url: URL
        let pixels: Int
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
        var task: Task<Void, Never>?
        var cancelling = false
    }
    private var jobs: [String: Job] = [:]
    private var pending: [String] = []
    private var active = 0
    private let pendingLimit = 128
    private let waiterLimit = 256
    private let perJobWaiterLimit = 16
    private var consumers = 0
    private let consumerLimit = 384 // Includes admission sleepers and registered waiters.
    private var cacheRevision: UInt64 = 0

    func clearCache() async {
        cacheRevision &+= 1
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

    func image(url: URL, pixels: Int) async -> UIImage? {
        let pixels = min(2048, max(1, pixels))
        let key = "\(url.absoluteString)|\(pixels)"
        guard !Task.isCancelled else { return nil }
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
                } else {
                    jobs[key] = Job(url: url, pixels: pixels, waiters: [waiter: continuation])
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
        while active < 4, !pending.isEmpty {
            let key = pending.removeFirst()
            guard let job = jobs[key], !job.waiters.isEmpty else { continue }
            active += 1
            let url = job.url
            let pixels = job.pixels
            jobs[key]?.task = Task.detached(priority: .utility) { [self] in
                var image: UIImage?
                do {
                    let data = try await Self.download(url)
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

    private nonisolated static func download(_ url: URL) async throws -> Data {
        let limit = 8 * 1024 * 1024
        // No URLCache or shared transfer can retain an oversized response after abort.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
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
