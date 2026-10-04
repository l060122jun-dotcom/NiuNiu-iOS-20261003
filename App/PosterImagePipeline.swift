import Foundation
import UIKit
import ImageIO

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

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 160
    }

    func image(url: URL, pixels: Int) async -> UIImage? {
        let pixels = min(2048, max(1, pixels))
        let key = "\(url.absoluteString)|\(pixels)"
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: key as NSString) { return image }
        let waiter = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
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
                    let (data, response) = try await URLSession.shared.data(from: url)
                    try Task.checkCancellation()
                    if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                        throw URLError(.badServerResponse)
                    }
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
