import Foundation
import Combine
import AVFoundation
import AVKit
import SwiftUI

enum OfflineDownloadFormat: String, Codable {
    case mp4, hls
}

enum OfflineDownloadState: String, Codable {
    case queued, downloading, completed, cancelled, failed

    var label: String {
        switch self {
        case .queued: return "等待下载"
        case .downloading: return "下载中"
        case .completed: return "已下载"
        case .cancelled: return "已取消"
        case .failed: return "下载失败"
        }
    }
}

struct OfflineDownload: Identifiable, Codable {
    let id: UUID
    let title: String
    let sourceURL: URL
    let headers: [String: String]
    let format: OfflineDownloadFormat
    let createdAt: Date
    var state: OfflineDownloadState = .queued
    var progress: Double = 0
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64?
    var errorMessage: String?
    // Relative to the sandbox home, which can change between app installations.
    var localRelativePath: String?
}

/// Public mutation methods must be called on the main thread (as SwiftUI actions are).
/// Background sessions own the actual transfers; the manifest owns UI metadata.
final class DownloadsStore: NSObject, ObservableObject {
    static let shared = DownloadsStore()

    @Published private(set) var items: [OfflineDownload] = []
    @Published private(set) var storageError: String?
    @Published private(set) var isRestoring = true

    private let rootURL: URL
    private let manifestURL: URL
    private var activeTasks: [UUID: URLSessionTask] = [:]
    private var pendingLocations: [UUID: URL] = [:]
    private var transferErrors: [UUID: String] = [:]
    private var backgroundCompletions: [String: () -> Void] = [:]
    private var pendingSave: DispatchWorkItem?
    private var manifestReadable = true
    private var verifiedItems: Set<UUID> = []
    private var validations: [UUID: UUID] = [:]
    private var validationCounts: [String: Int] = [:]
    private var finishedEventSessions: Set<String> = []

    private static var sessionPrefix: String {
        (Bundle.main.bundleIdentifier ?? "local.video") + ".offline-downloads"
    }

    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionPrefix + ".mp4")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private lazy var assetSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionPrefix + ".hls")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self,
                                         delegateQueue: .main)
    }()

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        rootURL = support.appendingPathComponent("OfflineDownloads", isDirectory: true)
        manifestURL = rootURL.appendingPathComponent("tasks.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            var root = rootURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                items = try JSONDecoder().decode([OfflineDownload].self,
                                                from: Data(contentsOf: manifestURL))
            }
        } catch {
            manifestReadable = false
            storageError = "读取下载记录失败：\(error.localizedDescription)"
        }
        restoreSessions()
    }

    /// Detects HLS by a .m3u8 path or query value. For extensionless HLS use the format overload.
    @discardableResult
    func add(title: String, url: URL, headers: [String: String] = [:]) -> UUID {
        let isHLS = url.pathExtension.lowercased() == "m3u8"
            || (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .contains { $0.value?.lowercased().contains(".m3u8") == true }
        return add(title: title, url: url, headers: headers, format: isHLS ? .hls : .mp4)
    }

    @discardableResult
    func add(title: String, url: URL, headers: [String: String] = [:],
             format: OfflineDownloadFormat) -> UUID {
        precondition(Thread.isMainThread)
        let id = UUID()
        var item = OfflineDownload(id: id, title: title.isEmpty ? url.lastPathComponent : title,
                                   sourceURL: url, headers: headers, format: format, createdAt: Date())
        guard manifestReadable else { return id }
        if !["https", "http"].contains(url.scheme?.lowercased() ?? "") || url.host == nil {
            item.state = .failed
            item.errorMessage = "仅支持有效的 HTTP / HTTPS 视频地址。"
        }
        items.insert(item, at: 0)
        persist()
        if !isRestoring && item.state == .queued { start(id) }
        return id
    }

    func cancel(_ id: UUID) {
        precondition(Thread.isMainThread)
        guard let index = index(id), [.queued, .downloading].contains(items[index].state) else { return }
        items[index].state = .cancelled
        items[index].errorMessage = nil
        validations.removeValue(forKey: id)
        verifiedItems.remove(id)
        activeTasks.removeValue(forKey: id)?.cancel()
        cleanPendingLocation(id)
        persist()
    }

    /// Removes files first; a filesystem error leaves the record visible for a later retry.
    func delete(_ id: UUID) {
        precondition(Thread.isMainThread)
        guard let index = index(id) else { return }
        cancel(id)
        validations.removeValue(forKey: id)
        verifiedItems.remove(id)
        cleanPendingLocation(id)
        guard pendingLocations[id] == nil, items[index].localRelativePath == nil else {
            persist()
            return
        }
        items.remove(at: index)
        persist()
    }

    /// Returns only verified, completed local files/packages. Never falls back to the network URL.
    func localURL(for id: UUID) -> URL? {
        precondition(Thread.isMainThread)
        guard let item = items.first(where: { $0.id == id }), item.state == .completed,
              verifiedItems.contains(id),
              let url = resolvedLocation(item), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Recheck the cache immediately before playback without loading media on the UI thread.
    fileprivate func preparePlayback(_ id: UUID, completion: @escaping (URL?) -> Void) {
        precondition(Thread.isMainThread)
        guard let index = index(id), items[index].state == .completed else { completion(nil); return }
        guard let url = resolvedLocation(items[index]) else {
            verifiedItems.remove(id)
            items[index].state = .failed
            items[index].errorMessage = "离线文件位置无效，请重新下载。"
            persist()
            completion(nil)
            return
        }
        let format = items[index].format
        validate(url, format: format) { [weak self] failure in
            guard let self = self, let index = self.index(id),
                  self.items[index].state == .completed,
                  self.resolvedLocation(self.items[index]) == url else { completion(nil); return }
            if let failure = failure {
                self.verifiedItems.remove(id)
                self.items[index].state = .failed
                self.items[index].errorMessage = failure
                self.persist()
                completion(nil)
            } else {
                self.verifiedItems.insert(id)
                completion(url)
            }
        }
    }

    /// Optional UIApplicationDelegate bridge for handleEventsForBackgroundURLSession.
    /// Return false if the identifier belongs to another subsystem.
    @discardableResult
    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard [Self.sessionPrefix + ".mp4", Self.sessionPrefix + ".hls"].contains(identifier) else { return false }
        backgroundCompletions[identifier] = completionHandler
        _ = fileSession
        _ = assetSession
        finishBackgroundEventsIfReady(identifier)
        return true
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func taskID(_ task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init(uuidString:))
    }

    private func resolvedLocation(_ item: OfflineDownload) -> URL? {
        guard let relative = item.localRelativePath, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(relative)
    }

    private func relativePath(_ url: URL) -> String? {
        let prefix = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    private func restoreSessions() {
        let group = DispatchGroup()
        let sessions: [URLSession] = [fileSession, assetSession]
        for session in sessions {
            group.enter()
            session.getAllTasks { [weak self] tasks in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self = self else { return }
                    guard self.manifestReadable else { return }
                    for task in tasks {
                        guard let id = self.taskID(task), let index = self.index(id),
                              [.queued, .downloading].contains(self.items[index].state) else {
                            task.cancel()
                            continue
                        }
                        self.activeTasks[id] = task
                        self.items[index].state = .downloading
                        if task.state == .suspended { task.resume() }
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            guard self.manifestReadable else {
                self.isRestoring = false
                self.finishAllBackgroundEventsIfReady()
                return
            }
            let checks = DispatchGroup()
            for index in self.items.indices {
                let item = self.items[index]
                if item.state == .downloading && self.activeTasks[item.id] == nil {
                    // A delegate may already be validating this task's completed file.
                    if self.validations[item.id] != nil { continue }
                    self.items[index].state = .failed
                    self.items[index].errorMessage = "系统中已找不到该下载任务，请重新下载。"
                    self.cleanPendingLocation(item.id)
                } else if item.state == .completed {
                    checks.enter()
                    self.preparePlayback(item.id) { _ in checks.leave() }
                } else if item.state == .failed || item.state == .cancelled {
                    self.cleanPendingLocation(item.id)
                }
            }
            checks.notify(queue: .main) {
                self.isRestoring = false
                self.persist()
                for id in self.items.filter({ $0.state == .queued }).map(\.id) { self.start(id) }
                self.finishAllBackgroundEventsIfReady()
            }
        }
    }

    private func start(_ id: UUID) {
        guard manifestReadable else { return }
        guard let index = index(id), items[index].state == .queued else { return }
        let item = items[index]
        let task: URLSessionTask
        switch item.format {
        case .mp4:
            var request = URLRequest(url: item.sourceURL)
            request.allHTTPHeaderFields = item.headers
            task = fileSession.downloadTask(with: request)
        case .hls:
            // AVFoundation's header option is best-effort; signed HLS URLs are preferable.
            let asset = AVURLAsset(url: item.sourceURL,
                                   options: ["AVURLAssetHTTPHeaderFieldsKey": item.headers])
            guard let assetTask = assetSession.makeAssetDownloadTask(asset: asset,
                assetTitle: item.title, assetArtworkData: nil, options: nil) else {
                items[index].state = .failed
                items[index].errorMessage = "系统无法创建 HLS 离线任务；请确认源支持点播离线下载。"
                persist()
                return
            }
            task = assetTask
        }
        task.taskDescription = id.uuidString
        activeTasks[id] = task
        items[index].state = .downloading
        items[index].errorMessage = nil
        persist()
        task.resume()
    }

    private func persist(throttled: Bool = false) {
        guard manifestReadable else { return }
        if throttled {
            guard pendingSave == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.pendingSave = nil
                self?.persist()
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            return
        }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil
        } catch {
            storageError = "保存下载记录失败：\(error.localizedDescription)"
        }
    }

    private func cleanPendingLocation(_ id: UUID) {
        guard manifestReadable else { return }
        let itemIndex = index(id)
        let recordedURL = itemIndex.flatMap { resolvedLocation(items[$0]) }
        let urls = Set([pendingLocations[id], recordedURL].compactMap { $0 })
        do {
            for url in urls {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            pendingLocations.removeValue(forKey: id)
            if let index = itemIndex { items[index].localRelativePath = nil }
        } catch {
            let message = "清理未完成文件失败：\(error.localizedDescription)"
            storageError = message
            if let index = itemIndex {
                items[index].errorMessage = (items[index].errorMessage.map { $0 + "\n" } ?? "") + message
            }
        }
    }

    private func validate(_ url: URL, format: OfflineDownloadFormat,
                          completion: @escaping (String?) -> Void) {
        Task.detached(priority: .utility) {
            var failure: String?
            if !FileManager.default.fileExists(atPath: url.path) {
                failure = "离线文件已丢失或被系统清理，请重新下载。"
            } else {
                let asset = AVURLAsset(url: url)
                do {
                    let playable = try await asset.load(.isPlayable)
                    if !playable { failure = "下载文件不是可播放的视频资源。" }
                    if format == .hls && asset.assetCache?.isPlayableOffline != true {
                        failure = "系统未确认 HLS 资源可以离线播放，请重新下载。"
                    }
                } catch {
                    failure = "离线视频校验失败：\(error.localizedDescription)"
                }
            }
            let result = failure
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func finishBackgroundEventsIfReady(_ identifier: String) {
        guard !isRestoring, finishedEventSessions.contains(identifier),
              validationCounts[identifier, default: 0] == 0,
              let completion = backgroundCompletions.removeValue(forKey: identifier) else { return }
        finishedEventSessions.remove(identifier)
        DispatchQueue.main.async { completion() }
    }

    private func finishAllBackgroundEventsIfReady() {
        for identifier in Array(finishedEventSessions) { finishBackgroundEventsIfReady(identifier) }
    }
}

extension DownloadsStore: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = taskID(downloadTask), let index = index(id), items[index].state == .downloading else { return }
        items[index].receivedBytes = totalBytesWritten
        items[index].expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        if totalBytesExpectedToWrite > 0 {
            items[index].progress = min(0.999, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }
        persist(throttled: true)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = taskID(downloadTask), let index = index(id), items[index].state == .downloading else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            transferErrors[id] = "下载未返回有效的 HTTP 响应。"
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            transferErrors[id] = "服务器返回 HTTP \(response.statusCode)：\(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"
            return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.contains("html"), !mime.contains("json"), !mime.contains("mpegurl") else {
            transferErrors[id] = "服务器返回了 \(mime)，并非 MP4 文件。无扩展名 HLS 地址请显式指定 .hls。"
            return
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
                transferErrors[id] = "服务器返回了空文件。"
                return
            }
            let destination = rootURL.appendingPathComponent(id.uuidString + ".mp4")
            try FileManager.default.moveItem(at: location, to: destination)
            pendingLocations[id] = destination
            items[index].localRelativePath = relativePath(destination)
            persist()
        } catch {
            transferErrors[id] = "保存视频文件失败：\(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = taskID(assetDownloadTask), let index = index(id), items[index].state == .downloading else { return }
        let duration = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        let start = CMTimeGetSeconds(timeRangeExpectedToLoad.start)
        guard duration.isFinite, duration > 0, start.isFinite else { return }
        // Merge ranges so overlapping audio/video reporting cannot inflate progress.
        let ranges = loadedTimeRanges.compactMap { value -> (Double, Double)? in
            let range = value.timeRangeValue
            let low = max(start, CMTimeGetSeconds(range.start))
            let high = min(start + duration, CMTimeGetSeconds(CMTimeRangeGetEnd(range)))
            return low.isFinite && high.isFinite && high > low ? (low, high) : nil
        }.sorted { $0.0 < $1.0 }
        var end = start
        var loaded: Double = 0
        for range in ranges {
            loaded += max(0, range.1 - max(end, range.0))
            end = max(end, range.1)
        }
        items[index].progress = min(0.999, max(0, loaded / duration))
        persist(throttled: true)
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard manifestReadable else { return }
        guard let id = taskID(assetDownloadTask) else { return }
        // Apple owns the package location: store it in place, never move an HLS package.
        pendingLocations[id] = location
        guard let index = index(id), items[index].state == .downloading else {
            cleanPendingLocation(id)
            persist()
            return
        }
        items[index].localRelativePath = relativePath(location)
        if items[index].localRelativePath == nil {
            transferErrors[id] = "HLS 文件位置不在当前应用沙盒内，无法保存离线记录。"
        }
        persist()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard manifestReadable else { return }
        guard let id = taskID(task) else { return }
        activeTasks.removeValue(forKey: id)
        let recordedError = transferErrors.removeValue(forKey: id)
        guard let index = index(id), items[index].state == .downloading else {
            cleanPendingLocation(id)
            persist()
            return
        }
        var failure = recordedError ?? error.map { "\(($0 as NSError).domain) (\(($0 as NSError).code))：\($0.localizedDescription)" }
        if let response = task.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            failure = "服务器返回 HTTP \(response.statusCode)。" + (failure.map { " \($0)" } ?? "")
        }
        let url = pendingLocations[id] ?? resolvedLocation(items[index])
        if failure == nil && url == nil { failure = "任务结束但没有可用的离线文件。" }
        if let failure = failure {
            items[index].state = .failed
            items[index].errorMessage = failure
            if pendingLocations[id] == nil, let url = url { pendingLocations[id] = url }
            cleanPendingLocation(id)
            persist()
            return
        }
        guard let url = url else { return }
        let token = UUID()
        validations[id] = token
        let identifier = session.configuration.identifier ?? ""
        validationCounts[identifier, default: 0] += 1
        validate(url, format: items[index].format) { [weak self] failure in
            guard let self = self else { return }
            self.validationCounts[identifier, default: 0] -= 1
            defer { self.finishBackgroundEventsIfReady(identifier) }
            guard self.validations[id] == token else { return }
            self.validations.removeValue(forKey: id)
            guard let index = self.index(id), self.items[index].state == .downloading else { return }
            if let failure = failure {
                self.items[index].state = .failed
                self.items[index].errorMessage = failure
                self.cleanPendingLocation(id)
            } else {
                self.pendingLocations.removeValue(forKey: id)
                self.verifiedItems.insert(id)
                self.items[index].state = .completed
                self.items[index].progress = 1
                self.items[index].errorMessage = nil
            }
            self.persist()
        }
        persist()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        persist()
        guard let identifier = session.configuration.identifier else { return }
        finishedEventSessions.insert(identifier)
        finishBackgroundEventsIfReady(identifier)
    }
}

struct DownloadsView: View {
    @ObservedObject private var store = DownloadsStore.shared
    @State private var selection: OfflinePlaybackSelection?
    @State private var pendingDeletion: UUID?
    @State private var playbackError: String?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.storageError {
                    Text(error).font(.footnote).foregroundColor(.red)
                }
                if store.isRestoring { ProgressView("正在恢复下载任务…") }
                if store.items.isEmpty && !store.isRestoring {
                    Text("暂无离线视频，在视频详情中添加下载。").foregroundColor(.secondary)
                }
                ForEach(store.items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).font(.headline)
                        HStack {
                            Text(item.state.label)
                            Spacer()
                            Text(item.format.rawValue.uppercased())
                            if item.state == .downloading || item.state == .completed {
                                Text("\(Int(item.progress * 100))%")
                            }
                        }.font(.caption).foregroundColor(.secondary)
                        if item.state == .downloading {
                            if item.format == .mp4 && item.expectedBytes == nil {
                                ProgressView()
                            } else {
                                ProgressView(value: item.progress)
                            }
                            if item.format == .mp4 {
                                Text(ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        if let error = item.errorMessage {
                            Text(error).font(.footnote).foregroundColor(.red).textSelection(.enabled)
                        }
                        HStack {
                            if item.state == .completed {
                                Button { play(item) } label: {
                                    Label("离线播放", systemImage: "play.circle")
                                }
                            }
                            if item.state == .queued || item.state == .downloading {
                                Button("取消", role: .cancel) { store.cancel(item.id) }
                            }
                            if item.state == .failed || item.state == .cancelled {
                                Button("重新下载") {
                                    store.add(title: item.title, url: item.sourceURL,
                                              headers: item.headers, format: item.format)
                                }
                            }
                            Spacer()
                            Button("删除", role: .destructive) { pendingDeletion = item.id }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 6)
                }
            }
            .navigationTitle("离线下载")
            .sheet(item: $selection) { selected in
                OfflinePlayerView(title: selected.title, url: selected.url)
            }
            .alert("删除离线下载？", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let id = pendingDeletion { store.delete(id) }
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("将取消任务并删除本地视频文件。")
            }
            .alert("无法播放", isPresented: Binding(
                get: { playbackError != nil }, set: { if !$0 { playbackError = nil } }
            )) {
                Button("好") { playbackError = nil }
            } message: { Text(playbackError ?? "") }
        }
    }

    private func play(_ item: OfflineDownload) {
        store.preparePlayback(item.id) { url in
            guard let url = url else {
                playbackError = "离线视频校验失败，请查看下载记录中的错误并重新下载。"
                return
            }
            selection = OfflinePlaybackSelection(id: item.id, title: item.title, url: url)
        }
    }
}

private struct OfflinePlaybackSelection: Identifiable {
    let id: UUID
    let title: String
    let url: URL
}

private struct OfflinePlayerView: View {
    let title: String
    @State private var player: AVPlayer
    @State private var playerError: String?
    @Environment(\.dismiss) private var dismiss

    init(title: String, url: URL) {
        self.title = title
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack {
                VideoPlayer(player: player)
                if let error = playerError { Text(error).foregroundColor(.red).padding() }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .onReceive(player.publisher(for: \.status)) { status in
                if status == .failed { playerError = player.error?.localizedDescription ?? "播放器初始化失败。" }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notice in
                guard let item = notice.object as? AVPlayerItem, item === player.currentItem else { return }
                playerError = (notice.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                    .localizedDescription ?? "离线视频播放失败。"
            }
        }
    }
}
