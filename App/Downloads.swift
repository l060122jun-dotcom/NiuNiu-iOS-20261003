import Foundation
import Combine
import AVFoundation
import AVKit
import SwiftUI

enum OfflineDownloadFormat: String, Codable {
    case mp4, hls, foregroundHLS
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
    // Optional fields decode as nil in manifests written by older versions.
    var sourceVideoID: String?
    var sourcePlayerID: String?
    var sourceEpisodeIndex: Int?
    var sourceEpisodeURL: String?

    /// Persisted or framework-provided numbers must never trap a SwiftUI Int conversion.
    var displayProgress: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }
}

struct OfflineDownloadOrigin {
    let videoID: String
    let playerID: String
    let episodeIndex: Int
    let episodeURL: String
}

/// All state and lazy background sessions are isolated to the main actor.
/// Background sessions own the actual transfers; the manifest owns UI metadata.
@MainActor
final class DownloadsStore: NSObject, ObservableObject {
    static let shared = DownloadsStore()

    @Published private(set) var items: [OfflineDownload] = []
    @Published private(set) var storageError: String?
    @Published private(set) var isRestoring = true
    @Published private(set) var retryingIDs: Set<UUID> = []

    private let rootURL: URL
    private let manifestURL: URL
    private let quarantineURL: URL
    private var manifestFailure: String?
    private var quarantineReadable = true
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
    private var foregroundWorkers: [UUID: ForegroundHLSDownload] = [:]
    private var foregroundRuns: [UUID: Task<Void, Never>] = [:]
    private var foregroundProbes: [UUID: ForegroundHLSProbe] = [:]
    private var lifecycleObserver: NSObjectProtocol?
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    private static var sessionPrefix: String {
        (Bundle.main.bundleIdentifier ?? "local.video") + ".offline-downloads"
    }

    private lazy var fileSession: URLSession = {
        // A fresh background configuration per identifier; do not set
        // waitsForConnectivity (background sessions ignore it), or reuse .shared.
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionPrefix + ".mp4")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private lazy var assetSession: AVAssetDownloadURLSession = {
        // AVAssetDownloadURLSession requires a background configuration; default
        // or ephemeral configurations raise an Objective-C exception, not Error.
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionPrefix + ".hls")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self,
                                         delegateQueue: .main)
    }()

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        rootURL = support.appendingPathComponent("OfflineDownloads", isDirectory: true)
        manifestURL = rootURL.appendingPathComponent("tasks.json")
        quarantineURL = rootURL.appendingPathComponent("quarantine-tasks.json")
        super.init()
        lifecycleObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stopForegroundForBackground() }
            }
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            guard try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ForegroundHLSDownload.Failure("离线目录不能是 symlink。")
            }
            var root = rootURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 else {
                    throw ForegroundHLSDownload.Failure("下载索引超出 16MB 安全上限。")
                }
                items = try JSONDecoder().decode([OfflineDownload].self,
                                                from: Data(contentsOf: manifestURL))
            }
        } catch {
            manifestReadable = false
            manifestFailure = "读取下载记录失败：\(error.localizedDescription)。原清单已保留；后台任务已停止，隔离文件可在此删除。"
            storageError = manifestFailure
            if FileManager.default.fileExists(atPath: quarantineURL.path) {
                do {
                    guard (try quarantineURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 else {
                        throw ForegroundHLSDownload.Failure("隔离索引超出 16MB 安全上限。")
                    }
                    items = try JSONDecoder().decode([OfflineDownload].self, from: Data(contentsOf: quarantineURL))
                }
                catch {
                    quarantineReadable = false
                    storageError = (manifestFailure ?? "") + "\n隔离索引读取失败：\(error.localizedDescription)。索引未覆盖。"
                }
            }
        }
        // Duplicate IDs break SwiftUI identity and incorrectly associate restored tasks.
        var restoredIDs: Set<UUID> = []
        if items.contains(where: { !restoredIDs.insert($0.id).inserted }) {
            manifestReadable = false
            quarantineReadable = false
            manifestFailure = "下载记录包含重复任务 ID；原索引已保留，请修复记录后重试。"
            storageError = manifestFailure
            items = []
        }
        for index in items.indices {
            items[index].progress = items[index].displayProgress
            items[index].receivedBytes = max(0, items[index].receivedBytes)
            if let expected = items[index].expectedBytes, expected <= 0 { items[index].expectedBytes = nil }
        }
        restoreSessions()
    }

    /// Detects HLS by a .m3u8 path or query value. For extensionless HLS use the format overload.
    @discardableResult
    func add(title: String, url: URL, headers: [String: String] = [:],
             origin: OfflineDownloadOrigin? = nil) -> UUID {
        let isHLS = url.pathExtension.lowercased() == "m3u8"
            || (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .contains { $0.value?.lowercased().contains(".m3u8") == true }
        return add(title: title, url: url, headers: headers, format: isHLS ? .hls : .mp4, origin: origin)
    }

    @discardableResult
    func add(title: String, url: URL, headers: [String: String] = [:],
             format: OfflineDownloadFormat, origin: OfflineDownloadOrigin? = nil) -> UUID {
        let id = UUID()
        var item = OfflineDownload(id: id, title: title.isEmpty ? url.lastPathComponent : title,
                                   sourceURL: url, headers: headers,
                                   format: isLoopback(url) && format != .mp4 ? .foregroundHLS : format, createdAt: Date())
        guard manifestReadable else { releaseProxy(url); return id }
        item.sourceVideoID = origin?.videoID
        item.sourcePlayerID = origin?.playerID
        item.sourceEpisodeIndex = origin?.episodeIndex
        item.sourceEpisodeURL = origin?.episodeURL
        if !["https", "http"].contains(url.scheme?.lowercased() ?? "") || url.host == nil {
            item.state = .failed
            item.errorMessage = "仅支持有效的 HTTP / HTTPS 视频地址。"
            releaseProxy(url)
        }
        items.insert(item, at: 0)
        persist()
        if !isRestoring && item.state == .queued { start(id) }
        return id
    }

    /// Re-resolve special URLs from authoritative detail data, never replay an expired proxy.
    @MainActor func retry(_ id: UUID) async {
        guard !retryingIDs.contains(id), let index = index(id),
              [.failed, .cancelled].contains(items[index].state) else { return }
        let old = items[index]
        retryingIDs.insert(id)
        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                self.retryingIDs.remove(id)
                self.retryTasks[id] = nil
                self.persist()
            }
            do {
                try Task.checkCancellation()
                guard self.manifestReadable, !self.isRestoring else {
                    throw ForegroundHLSDownload.Failure(self.storageError ?? "下载记录正在恢复，请稍后再试。")
                }
                let origin: OfflineDownloadOrigin?
                if let videoID = old.sourceVideoID, let playerID = old.sourcePlayerID,
                   let episodeIndex = old.sourceEpisodeIndex, let episodeURL = old.sourceEpisodeURL {
                    origin = OfflineDownloadOrigin(videoID: videoID, playerID: playerID,
                                                   episodeIndex: episodeIndex, episodeURL: episodeURL)
                } else { origin = nil }
                if origin != nil || self.isLoopback(old.sourceURL) || old.format == .foregroundHLS {
                    guard let origin = origin, !origin.videoID.isEmpty, !origin.playerID.isEmpty,
                          origin.episodeIndex >= 0, !origin.episodeURL.isEmpty else {
                        throw ForegroundHLSDownload.Failure("下载记录没有有效影片/源/集元数据，不能复用旧授权地址；请从视频详情重新下载。")
                    }
                    guard !(self.isLoopback(old.sourceURL) || old.format == .foregroundHLS) || UIApplication.shared.applicationState != .background else {
                        throw ForegroundHLSDownload.Failure("特殊源需保持 App 前台解析并完成下载。")
                    }
                    let video = try await APIClient.shared.detail(id: origin.videoID)
                    try Task.checkCancellation()
                    let matchingSources = video.sources.filter { $0.id == origin.playerID }
                    guard video.id == origin.videoID, matchingSources.count == 1,
                          let source = matchingSources.first, source.episodes.indices.contains(origin.episodeIndex),
                          source.episodes[origin.episodeIndex].url == origin.episodeURL else {
                        throw ForegroundHLSDownload.Failure("影片详情的原源/集已变更或不存在；未猜测其他影片，请从详情选择后重新下载。")
                    }
                    let result = try await APIClient.shared.resolve(episode: source.episodes[origin.episodeIndex],
                                                                    source: source.id, purpose: .download)
                    var transferred = false
                    defer { if !transferred { SpecialSourceResolver.shared.releaseDownload(url: result.url) } }
                    try Task.checkCancellation()
                    guard !self.isLoopback(result.url) || UIApplication.shared.applicationState != .background,
                          let current = self.index(id), [.failed, .cancelled].contains(self.items[current].state) else {
                        throw ForegroundHLSDownload.Failure("重试已停止或原记录已删除，未加入新任务。")
                    }
                    let addedID = self.add(title: old.title, url: result.url, headers: result.headers,
                                          format: old.format == .foregroundHLS ? .hls : old.format, origin: origin)
                    guard let added = self.items.first(where: { $0.id == addedID }),
                          [.queued, .downloading, .completed].contains(added.state) else {
                        throw ForegroundHLSDownload.Failure(self.items.first(where: { $0.id == addedID })?.errorMessage
                            ?? self.storageError ?? "重新解析成功但下载入队失败。")
                    }
                    transferred = true
                } else {
                    throw ForegroundHLSDownload.Failure("旧下载缺少影片/源/集元数据，不能确认签名地址仍有效；请从视频详情重新下载。")
                }
            } catch {
                if let current = self.index(id) {
                    self.items[current].errorMessage = Task.isCancelled
                        ? "重新解析已取消；未复用失效代理。" : "重新下载失败：\(error.localizedDescription)"
                }
            }
        }
        retryTasks[id] = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func cancelRetry(_ id: UUID) {
        retryTasks[id]?.cancel()
    }

    func cancel(_ id: UUID) {
        guard let index = index(id), [.queued, .downloading].contains(items[index].state) else { return }
        releaseProxy(items[index].sourceURL)
        items[index].state = .cancelled
        items[index].errorMessage = nil
        validations.removeValue(forKey: id)
        verifiedItems.remove(id)
        activeTasks.removeValue(forKey: id)?.cancel()
        foregroundWorkers[id]?.cancel()
        foregroundRuns[id]?.cancel()
        foregroundProbes.removeValue(forKey: id)?.cancel()
        if !isLoopback(items[index].sourceURL) { cleanPendingLocation(id) }
        persist()
    }

    /// Removes files first; a filesystem error leaves the record visible for a later retry.
    func delete(_ id: UUID) {
        cancelRetry(id)
        guard let index = index(id) else { return }
        cancel(id)
        // A cancelled async transfer must settle before its UUID directory can be deleted.
        if foregroundRuns[id] != nil {
            items[index].errorMessage = "下载正在停止；partial 已保留，请稍后再次删除。"
            persist()
            return
        }
        releaseProxy(items[index].sourceURL)
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
        guard let item = items.first(where: { $0.id == id }), item.state == .completed,
              verifiedItems.contains(id),
              let url = resolvedLocation(item), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Recheck the cache immediately before playback without loading media on the UI thread.
    fileprivate func preparePlayback(_ id: UUID, completion: @escaping (URL?) -> Void) {
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
        guard [Self.sessionPrefix + ".mp4", Self.sessionPrefix + ".hls"].contains(identifier) else { return false }
        backgroundCompletions[identifier] = completionHandler
        _ = fileSession
        _ = assetSession
        finishBackgroundEventsIfReady(identifier)
        return true
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func isLoopback(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.") || host == "0.0.0.0"
    }

    private func releaseProxy(_ url: URL) {
        guard isLoopback(url) else { return }
        Task { @MainActor in SpecialSourceResolver.shared.releaseDownload(url: url) }
    }

    private func taskID(_ task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init(uuidString:))
    }

    private func taskMediaURL(_ task: URLSessionTask) -> URL? {
        if let assetTask = task as? AVAssetDownloadTask { return assetTask.urlAsset.url }
        return task.originalRequest?.url
    }

    private func resolvedLocation(_ item: OfflineDownload) -> URL? {
        guard let relative = item.localRelativePath, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(relative)
        if url.deletingLastPathComponent().pathExtension == "foreground" {
            guard url.deletingLastPathComponent().deletingPathExtension().lastPathComponent == item.id.uuidString else { return nil }
        }
        return ownedLocation(url) ? url : nil
    }

    /// Only our UUID MP4 directory or Apple's sandbox-local HLS packages may be deleted.
    private func ownedLocation(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let package = url.deletingLastPathComponent()
        if ["local.m3u8", "video.mp4"].contains(url.lastPathComponent),
           package.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL,
           package.pathExtension == "foreground", UUID(uuidString: package.deletingPathExtension().lastPathComponent) != nil {
            return ForegroundHLSDownload.safePackage(package)
        }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        if path.hasPrefix(root), url.pathExtension.lowercased() == "mp4",
           UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil { return true }
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(library) && url.pathExtension.lowercased() == "movpkg"
    }

    private func quarantine(_ task: URLSessionTask, location: URL? = nil) -> UUID {
        if let url = taskMediaURL(task) { releaseProxy(url) }
        if let asset = task as? AVAssetDownloadTask { releaseProxy(asset.urlAsset.url) }
        let id = taskID(task) ?? UUID()
        task.taskDescription = id.uuidString
        if index(id) == nil {
            let url = taskMediaURL(task)
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            var item = OfflineDownload(id: id, title: "隔离下载 · " + url.lastPathComponent,
                sourceURL: url, headers: [:], format: task is AVAssetDownloadTask ? .hls : .mp4, createdAt: Date())
            item.state = .failed
            item.errorMessage = "原下载清单不可读，任务已停止；未猜测原下载信息。"
            items.append(item)
        }
        if let location = location, let index = index(id) {
            if ownedLocation(location), let relative = relativePath(location) {
                items[index].localRelativePath = relative
                items[index].state = .failed
            } else {
                items[index].errorMessage = "隔离文件不在本 App 可管理的离线目录内，未删除该文件。"
            }
        }
        persist()
        return id
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
                    guard self.manifestReadable else {
                        for task in tasks { _ = self.quarantine(task); task.cancel() }
                        return
                    }
                    for task in tasks {
                        guard let id = self.taskID(task), let index = self.index(id),
                              [.queued, .downloading].contains(self.items[index].state) else {
                            if let url = self.taskMediaURL(task) { self.releaseProxy(url) }
                            task.cancel()
                            continue
                        }
                        self.activeTasks[id] = task
                        if self.isLoopback(self.items[index].sourceURL) {
                            self.releaseProxy(self.items[index].sourceURL)
                            self.items[index].state = .failed
                            self.items[index].errorMessage = "当前不支持本地代理后台下载；已停止旧任务。"
                            self.activeTasks[id] = nil
                            task.cancel()
                            continue
                        }
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
                if self.isLoopback(item.sourceURL), [.queued, .downloading].contains(item.state) {
                    self.items[index].state = .failed
                    self.items[index].errorMessage = "前台下载被中断，partial 已保留。必须保持 App 前台并重新解析特殊源后重新下载；不支持后台续传。"
                    self.releaseProxy(item.sourceURL)
                    continue
                }
                if item.state == .downloading && self.activeTasks[item.id] == nil {
                    // A delegate may already be validating this task's completed file.
                    if self.validations[item.id] != nil { continue }
                    if let url = self.resolvedLocation(item) {
                        checks.enter()
                        self.recoverPersistedFile(item.id, url: url) { checks.leave() }
                        continue
                    }
                    self.items[index].state = .failed
                    self.items[index].errorMessage = "系统中已找不到该下载任务，请重新下载。"
                    self.cleanPendingLocation(item.id)
                } else if item.state == .completed {
                    checks.enter()
                    self.preparePlayback(item.id) { _ in checks.leave() }
                } else if item.state == .failed || item.state == .cancelled {
                    // A failed verification retains its persisted file for explicit deletion.
                    if !self.isLoopback(item.sourceURL) && (item.state == .cancelled || item.localRelativePath == nil) {
                        self.cleanPendingLocation(item.id)
                    }
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
        // Recheck persisted records too, before calling Foundation/AVFoundation.
        if let failure = transferInputFailure(item) {
            items[index].state = .failed
            items[index].errorMessage = failure
            releaseProxy(item.sourceURL)
            persist()
            return
        }
        if isLoopback(item.sourceURL) {
            guard foregroundRuns.count < 4 else { return }
            startForeground(id)
            return
        }
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
        case .foregroundHLS:
            items[index].state = .failed
            items[index].errorMessage = "前台 HLS 需要重新解析取得有效本地代理地址。"
            persist()
            return
        }
        task.taskDescription = id.uuidString
        activeTasks[id] = task
        items[index].state = .downloading
        items[index].errorMessage = nil
        persist()
        task.resume()
    }

    private func persist(throttled: Bool = false) {
        guard manifestReadable || quarantineReadable else { return }
        if throttled {
            guard pendingSave == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.pendingSave = nil
                    self?.persist()
                }
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            return
        }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: manifestReadable ? manifestURL : quarantineURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = manifestReadable ? nil : manifestFailure
        } catch {
            storageError = "保存下载记录失败：\(error.localizedDescription)"
        }
    }

    private func transferInputFailure(_ item: OfflineDownload) -> String? {
        let url = item.sourceURL
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            return "下载地址必须是无内嵌账号密码的有效 HTTP / HTTPS URL。"
        }
        var names: Set<String> = []
        for (key, value) in item.headers {
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }),
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  names.insert(key.lowercased()).inserted else {
                return "下载请求头包含非法字符或大小写重复字段，未创建系统任务。"
            }
        }
        return nil
    }

    private func cleanPendingLocation(_ id: UUID) {
        let itemIndex = index(id)
        if let index = itemIndex, isLoopback(items[index].sourceURL),
           let relative = items[index].localRelativePath {
            let expected = rootURL.appendingPathComponent(id.uuidString + ".foreground")
            let local = expected.appendingPathComponent(items[index].format == .foregroundHLS ? "local.m3u8" : "video.mp4")
            if relativePath(local) == relative,
               !FileManager.default.fileExists(atPath: expected.path),
               (try? expected.resourceValues(forKeys: [.isSymbolicLinkKey])) == nil {
                items[index].localRelativePath = nil
            }
        }
        let recordedURL = itemIndex.flatMap { resolvedLocation(items[$0]) }
        let urls = Set([pendingLocations[id], recordedURL].compactMap { $0 })
        do {
            for url in urls {
                guard ownedLocation(url) else {
                    throw NSError(domain: "OfflineDownloads", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "文件不属于本 App 离线目录，未删除。"])
                }
                let removal = url.deletingLastPathComponent().pathExtension == "foreground" ? url.deletingLastPathComponent() : url
                if FileManager.default.fileExists(atPath: removal.path) { try FileManager.default.removeItem(at: removal) }
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
                          probeID: UUID = UUID(),
                          completion: @escaping (String?) -> Void) {
        if format == .foregroundHLS {
            let token = probeID
            Task.detached(priority: .utility) { [weak self] in
                do {
                    try ForegroundHLSDownload.validate(url)
                    await MainActor.run {
                        guard let self = self else { completion("下载管理器已释放。"); return }
                        guard UIApplication.shared.applicationState != .background,
                              self.index(probeID).map({ self.items[$0].state == .downloading || self.items[$0].state == .completed }) ?? true else {
                            completion("前台 HLS 校验已停止，请保持 App 前台完成下载。")
                            return
                        }
                        let probe = ForegroundHLSProbe()
                        self.foregroundProbes[token] = probe
                        probe.check(url) { [weak self] failure in
                            self?.foregroundProbes.removeValue(forKey: token)
                            completion(failure)
                        }
                    }
                } catch {
                    let message = "本地 HLS 校验失败：\(error.localizedDescription)"
                    DispatchQueue.main.async { completion(message) }
                }
            }
            return
        }
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

    private func recoverPersistedFile(_ id: UUID, url: URL, completion: @escaping () -> Void) {
        guard let index = index(id) else { completion(); return }
        let token = UUID()
        validations[id] = token
        validate(url, format: items[index].format) { [weak self] failure in
            defer { completion() }
            guard let self = self, self.validations[id] == token else { return }
            self.validations[id] = nil
            guard let index = self.index(id), self.items[index].state == .downloading,
                  self.resolvedLocation(self.items[index]) == url else { return }
            if let failure = failure {
                self.items[index].state = .failed
                self.items[index].errorMessage = failure
                // Retain the failed file for an explicit user delete, not startup destruction.
            } else {
                self.items[index].state = .completed
                self.items[index].progress = 1
                self.items[index].errorMessage = nil
                self.verifiedItems.insert(id)
            }
            self.persist()
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

    private func stopForegroundForBackground() {
        for task in retryTasks.values { task.cancel() }
        for index in items.indices where isLoopback(items[index].sourceURL) && [.queued, .downloading].contains(items[index].state) {
            let id = items[index].id
            items[index].state = .failed
            items[index].errorMessage = "App 已进入后台，特殊源前台下载已停止并保留 partial；请保持前台、重新解析源后重下。不支持系统后台下载/断点续传。"
            foregroundWorkers[id]?.cancel()
            foregroundRuns[id]?.cancel()
            releaseProxy(items[index].sourceURL)
        }
        for probe in Array(foregroundProbes.values) { probe.cancel() }
        persist()
    }

    private func startForeground(_ id: UUID) {
        guard let index = index(id), UIApplication.shared.applicationState != .background else {
            stopForegroundForBackground(); return
        }
        let item = items[index]
        let package = rootURL.appendingPathComponent(id.uuidString + ".foreground", isDirectory: true)
        let local = package.appendingPathComponent(item.format == .foregroundHLS ? "local.m3u8" : "video.mp4")
        let worker = ForegroundHLSDownload(origin: item.sourceURL, headers: item.headers) { [weak self] bytes, expected in
            DispatchQueue.main.async {
                guard let self = self, let index = self.index(id), self.items[index].state == .downloading else { return }
                // HLS only publishes a total after finalizing the real local package.
                // Late delegate callbacks must not erase that final total or inflate it.
                if item.format == .foregroundHLS, self.items[index].expectedBytes != nil, expected == nil { return }
                self.items[index].receivedBytes = item.format == .foregroundHLS && expected != nil
                    ? bytes : max(self.items[index].receivedBytes, bytes)
                self.items[index].expectedBytes = expected
                if let expected = expected, expected > 0 {
                    self.items[index].progress = min(0.999, Double(bytes) / Double(expected))
                }
                self.persist(throttled: true)
            }
        }
        foregroundWorkers[id] = worker
        items[index].state = .downloading
        items[index].localRelativePath = relativePath(local)
        items[index].errorMessage = "特殊源仅限前台下载；切后台会停止并保留 partial。HLS 总大小在资源全部完成前未知。"
        persist()
        foregroundRuns[id] = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                self.foregroundRuns[id] = nil
                self.foregroundWorkers[id] = nil
                self.releaseProxy(item.sourceURL)
                self.persist()
                if UIApplication.shared.applicationState != .background {
                    for queued in self.items.filter({ $0.state == .queued }).map(\.id) { self.start(queued) }
                }
            }
            do {
                let saved = try await worker.run(package: package, hls: item.format == .foregroundHLS)
                try Task.checkCancellation()
                let failure: String? = await withCheckedContinuation { continuation in
                    self.validate(saved, format: item.format, probeID: id) { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                if let failure = failure { throw ForegroundHLSDownload.Failure(failure) }
                guard let index = self.index(id), self.items[index].state == .downloading else { return }
                self.items[index].state = .completed
                self.items[index].progress = 1
                self.items[index].errorMessage = nil
                self.verifiedItems.insert(id)
            } catch {
                guard let index = self.index(id), self.items[index].state == .downloading else { return }
                self.items[index].state = .failed
                self.items[index].errorMessage = "前台下载失败（partial 已保留）：\(error.localizedDescription)；需要前台重新解析后重下。"
            }
        }
    }
}

// Foundation's Objective-C delegate requirements are nonisolated. These sessions
// explicitly deliver ALL callbacks on OperationQueue.main, including temporary-file
// callbacks which must finish moving the file before returning to URLSession.
// @preconcurrency bridges that legacy protocol without unsafe MainActor.assumeIsolated.
extension DownloadsStore: @preconcurrency URLSessionDownloadDelegate, @preconcurrency AVAssetDownloadDelegate {
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
        if !manifestReadable {
            let id = quarantine(downloadTask)
            do {
                let destination = rootURL.appendingPathComponent(id.uuidString + ".mp4")
                try FileManager.default.moveItem(at: location, to: destination)
                _ = quarantine(downloadTask, location: destination)
            } catch { storageError = (manifestFailure ?? "") + "\n隔离文件保存失败：\(error.localizedDescription)" }
            return
        }
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
        guard manifestReadable else { _ = quarantine(assetDownloadTask, location: location); return }
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
        if let id = taskID(task), let index = index(id) { releaseProxy(items[index].sourceURL) }
        else if let url = taskMediaURL(task) { releaseProxy(url) }
        guard manifestReadable else {
            let id = quarantine(task)
            if let error = error, let index = index(id) { items[index].errorMessage = error.localizedDescription }
            persist()
            return
        }
        guard let id = taskID(task) else { return }
        activeTasks.removeValue(forKey: id)
        let recordedError = transferErrors.removeValue(forKey: id)
        guard let index = index(id), items[index].state == .downloading else {
            cleanPendingLocation(id)
            persist()
            return
        }
        var failure = recordedError ?? error.map { "\(($0 as NSError).domain) (\(($0 as NSError).code))：\($0.localizedDescription)" }
        // AVAssetDownloadTask throws Objective-C exceptions for inherited
        // response/currentRequest accessors on the connected iPhone (crash IPS).
        if !(task is AVAssetDownloadTask), let response = task.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
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

@MainActor struct DownloadsView: View {
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
                            if item.state == .completed || (item.state == .downloading && (item.format != .foregroundHLS || item.expectedBytes != nil)) {
                                Text("\(Int(item.displayProgress * 100))%")
                            }
                        }.font(.caption).foregroundColor(.secondary)
                        if item.state == .downloading {
                            if (item.format == .mp4 || item.format == .foregroundHLS) && item.expectedBytes == nil {
                                ProgressView()
                            } else {
                                ProgressView(value: item.displayProgress)
                            }
                            if item.format == .mp4 || item.format == .foregroundHLS {
                                Text(ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
                                     + (item.format == .foregroundHLS && item.expectedBytes == nil ? " · 总大小未知" : ""))
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
                                if store.retryingIDs.contains(item.id) {
                                    ProgressView("重新解析…")
                                    Button("取消重试") { store.cancelRetry(item.id) }
                                } else {
                                    Button("重新下载") {
                                        Task { @MainActor in await store.retry(item.id) }
                                    }.disabled(store.isRestoring)
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

@MainActor private struct OfflinePlayerView: View {
    let title: String
    let url: URL

    var body: some View {
        // Apple's asset-download package is not an FFmpeg-readable media file.
        // Never pass a .movpkg URL to IJK or silently fall back for ordinary MP4.
        if url.pathExtension.lowercased() == "movpkg" {
            SystemOfflineHLSPlayerView(title: title, url: url)
        } else {
            OfflineIJKPlayerView(title: title, url: url)
        }
    }
}

@MainActor private struct OfflineIJKPlayerView: View {
    let title: String
    let url: URL
    @StateObject private var playback = PlaybackController()
    @StateObject private var interaction = AndroidPlayerInteraction()
    @State private var locked = false
    @State private var fullScreen = false
    @State private var fill = false
    @State private var explanation: String?
    @Environment(\.dismiss) private var dismiss

    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        PlaybackSurface(controller: playback, fill: fill)
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { interaction.toggle() }
                        AndroidPlayerControls(
                            interaction: interaction, locked: $locked,
                            sessionID: url.absoluteString, title: title,
                            time: playback.position, duration: playback.duration,
                            playing: playback.isPlaying, fullScreen: fullScreen,
                            wide: geometry.size.width >= 600, fill: fill, canNext: false,
                            rate: playback.rate, rates: rates, danmakuShown: false,
                            onBack: { if fullScreen { fullScreen = false } else { dismiss() } },
                            onPlay: togglePlayback, onNext: {}, onSeek: seek,
                            onFullScreen: { fullScreen.toggle(); interaction.show() },
                            onFill: { fill.toggle() },
                            onSettings: { explanation = "离线 MP4 使用 B站 IJK / FFmpeg。全屏扩展当前播放页，不强制设备横屏。\n\(playback.pictureInPictureStatus)" },
                            onEpisodes: { explanation = "离线播放仅使用已校验的本地文件，不提供在线选集或换源。" },
                            onDanmaku: { explanation = "离线视频尚未提供离线弹幕。" },
                            onRate: { playback.setRate($0) },
                            onCast: { explanation = playback.airPlayStatus }
                        ) {
                            Button("后退15秒") { seek(playback.position - 15) }
                            Button("前进15秒") { seek(playback.position + 15) }
                            DisclosureGroup("播放倍速") {
                                ForEach(rates, id: \.self) { rate in
                                    Button(String(format: "%g×", rate)) { playback.setRate(rate) }
                                }
                            }
                            Button(fill ? "画面适应" : "画面填充") { fill.toggle() }
                            Button("画中画支持说明") { explanation = playback.pictureInPictureStatus }
                        }
                        if let error = playback.error {
                            VStack(spacing: 12) {
                                Text(error).font(.footnote).multilineTextAlignment(.center)
                                Button("重试 IJK") { playback.load(url); interaction.show() }
                            }
                            .foregroundColor(.white).padding()
                            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding()
                        } else if !playback.isReady || playback.isSeeking {
                            ProgressView(playback.isSeeking ? "正在定位…" : "IJK 正在打开本地视频…")
                                .tint(.white).foregroundColor(.white).allowsHitTesting(false)
                        }
                    }
                    .frame(height: fullScreen ? geometry.size.height : min(geometry.size.height, max(220, geometry.size.width * 9 / 16)))
                    if !fullScreen {
                        HStack {
                            Button { seek(playback.position - 15) } label: { Label("后退15秒", systemImage: "gobackward.15") }
                            Spacer()
                            Menu(String(format: "%g×", playback.rate)) {
                                ForEach(rates, id: \.self) { rate in
                                    Button(String(format: "%g×", rate)) { playback.setRate(rate) }
                                }
                            }
                            Spacer()
                            Button { seek(playback.position + 15) } label: { Label("前进15秒", systemImage: "goforward.15") }
                        }.font(.footnote).padding()
                        Text("离线 MP4 · B站 IJK / FFmpeg\n当前 IJK 不支持系统画中画；退出播放页会停止播放。")
                            .font(.footnote).foregroundColor(.secondary).padding(.horizontal)
                        Spacer(minLength: 0)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .statusBarHidden(fullScreen)
            .onAppear { playback.load(url) }
            .onDisappear {
                interaction.cancel()
                playback.onProgress = nil
                playback.onTime = nil
                playback.onEnd = nil
                playback.stop()
            }
            .alert("离线播放说明", isPresented: Binding(
                get: { explanation != nil }, set: { if !$0 { explanation = nil } }
            )) {
                Button("好") { explanation = nil }
            } message: { Text(explanation ?? "") }
        }
    }

    private func togglePlayback() {
        if playback.isPlaying { playback.pause() } else { playback.play() }
        interaction.show()
    }

    private func seek(_ seconds: Double) {
        guard playback.isReady, playback.duration > 0, !playback.isSeeking else { return }
        playback.seek(min(playback.duration, max(0, seconds)))
        interaction.show()
    }
}

@MainActor private struct SystemOfflineHLSPlayerView: View {
    let title: String
    @State private var player: AVPlayer
    @State private var item: AVPlayerItem
    @State private var playerError: String?
    @Environment(\.dismiss) private var dismiss

    init(title: String, url: URL) {
        self.title = title
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        _item = State(initialValue: item)
        _player = State(initialValue: AVPlayer(playerItem: item))
    }

    var body: some View {
        NavigationStack {
            VStack {
                VideoPlayer(player: player)
                Text("系统离线 HLS · AVPlayer\nApple .movpkg 离线包不支持 IJK，使用系统资产播放器兼容播放。\n本页尚未实现画中画续播；退出页面会暂停并释放播放项。")
                    .font(.footnote).foregroundColor(.secondary).padding()
                if let error = playerError { Text(error).foregroundColor(.red).padding() }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if player.currentItem == nil { player.replaceCurrentItem(with: item) }
                player.play()
            }
            .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
            .onReceive(item.publisher(for: \.status)) { status in
                if status == .failed { playerError = item.error?.localizedDescription ?? "系统离线 HLS 资源打开失败。" }
            }
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
