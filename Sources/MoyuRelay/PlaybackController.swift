import AppKit
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum PlaybackKind: String, CaseIterable, Identifiable {
    case story = "测试分镜", local = "本地视频", mirror = "iPhone 镜像"
    var id: String { rawValue }
}

enum LocalPlaybackState {
    case empty, paused, waiting, playing, failed
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published var kind: PlaybackKind = .mirror
    @Published private(set) var isPlaying = false
    @Published private(set) var localState: LocalPlaybackState = .empty
    @Published var position: Double = 0
    @Published var duration: Double = 36
    @Published var videoNames: [String] = []
    @Published var videoIndex = 0
    @Published var message = "iPhone 镜像手动播放，AI 完成时提醒"
    let player = AVPlayer()
    private var videos: [URL] = []
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var lastTick = Date()
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    // Intent controls queue advancement; AVPlayer observations control the UI.
    private var wantsPlayback = false
    private var endedCurrentItem = false
    private var currentItemFailed = false
    private var failureReported = false
    private var itemGeneration: UInt64 = 0

    init() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshLocalObservation() }
        }
        playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshLocalObservation() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Read the current item now; a queued time value can belong to
                // the previous episode after replaceCurrentItem has completed.
                self?.refreshLocalObservation()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let item = notification.object as? AVPlayerItem else { return }
                self?.didReachEnd(item)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.kind == .local,
                      let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                self.currentItemFailed = true
                self.refreshLocalObservation()
            }
        }
    }

    var hasLocalVideos: Bool { !videos.isEmpty }

    var observedStateCaption: String {
        guard kind == .local else {
            return kind == .story ? (isPlaying ? "分镜播放中" : "分镜已暂停") : "镜像播放状态需单独确认"
        }
        switch localState {
        case .empty: return "尚未选择视频"
        case .paused: return "已暂停"
        case .waiting: return "正在准备或缓冲"
        case .playing: return "正在播放"
        case .failed: return "视频无法播放"
        }
    }

    var episode: Int { min(2, Int(position / 12)) + 1 }
    var storyTitle: String { ["离谱的开场", "总裁的提示词", "命运的停止键"][episode - 1] }
    var storyLine: (String, String) {
        let frames = [
            ("旁白", "重生第一天，我把工作交给了 AI。"),
            ("同事", "你怎么还有空看短剧？"),
            ("我", "它还在思考，我先活一集。"),
            ("总裁", "三分钟，我要这个项目的全部资料。"),
            ("我", "收到。AI，三分钟。"),
            ("旁白", "他从没见过如此懂得转述的员工。"),
            ("系统", "谁才是真正的继承人？"),
            ("AI", "方案已完成，请你确认。"),
            ("我", "家产等我点完确认再继承。")
        ]
        return frames[min(frames.count - 1, max(0, Int(position / 4)))]
    }

    func changeKind(_ newKind: PlaybackKind) {
        pause()
        kind = newKind
        position = 0
        duration = newKind == .story ? 36 : 1
        if newKind == .local, !videos.isEmpty { loadCurrentVideo() }
        message = newKind == .story ? "虚构文字分镜 · 用于验证切换体验" : newKind == .local ? "选择本地视频，按文件名顺序播放" : "连接 iPhone 镜像，手机视频由你手动播放"
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择一部或多集视频，将按文件名自然顺序播放"
        guard panel.runModal() == .OK else { return }
        selectVideos(panel.urls)
    }

    private func selectVideos(_ urls: [URL]) {
        pause()
        videos = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        videoNames = videos.map(\.lastPathComponent)
        videoIndex = 0
        kind = .local
        loadCurrentVideo()
        if localState != .failed { message = videos.isEmpty ? "请先选择本地视频" : "已载入 \(videos.count) 集，等待 AI 开工" }
    }

    private func loadCurrentVideo() {
        itemGeneration &+= 1
        let generation = itemGeneration
        statusObservation?.invalidate()
        statusObservation = nil
        endedCurrentItem = false
        currentItemFailed = false
        failureReported = false
        player.pause()
        guard videos.indices.contains(videoIndex) else {
            wantsPlayback = false
            player.replaceCurrentItem(with: nil)
            refreshLocalObservation()
            return
        }
        let item = AVPlayerItem(url: videos[videoIndex])
        player.replaceCurrentItem(with: item)
        position = 0
        duration = 1
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self, weak observedItem] in
                guard let self, let observedItem, self.itemGeneration == generation,
                      observedItem === self.player.currentItem else { return }
                self.refreshLocalObservation()
            }
        }
        if wantsPlayback { player.play() }
        refreshLocalObservation()
    }

    func play() {
        guard kind != .mirror else { return }
        if kind == .local {
            guard !videos.isEmpty else { message = "请先选择本地视频"; onFailure?(message); return }
            refreshLocalObservation()
            guard localState != .failed else { return }
            wantsPlayback = true
            if endedCurrentItem {
                videoIndex = videoIndex + 1 < videos.count ? videoIndex + 1 : 0
                loadCurrentVideo()
            } else if player.currentItem == nil {
                loadCurrentVideo()
            } else {
                player.play()
                refreshLocalObservation()
            }
            return
        }
        if position >= 36 { position = 0 }
        lastTick = Date()
        isPlaying = true
    }

    func pause() {
        tick()
        wantsPlayback = false
        player.pause()
        if kind == .local { refreshLocalObservation() }
        else { isPlaying = false }
    }

    private func refreshLocalObservation() {
        guard kind == .local else { return }
        guard let item = player.currentItem else {
            localState = .empty
            isPlaying = false
            position = 0
            duration = 1
            return
        }
        let seconds = item.currentTime().seconds
        position = max(0, seconds.isFinite ? seconds : 0)
        let total = item.duration.seconds
        duration = total.isFinite && total > 0 ? total : 1
        if currentItemFailed || item.status == .failed || player.status == .failed {
            currentItemFailed = true
            wantsPlayback = false
            player.pause()
            localState = .failed
            isPlaying = false
            if !failureReported {
                failureReported = true
                message = "视频无法播放，请换一个文件"
                onFailure?("视频无法播放，请检查格式或文件是否可用")
            }
            return
        }
        switch player.timeControlStatus {
        case .playing where item.status == .readyToPlay:
            localState = .playing
        case .waitingToPlayAtSpecifiedRate:
            localState = .waiting
        case .paused where item.status == .readyToPlay:
            localState = .paused
        default:
            localState = .waiting
        }
        isPlaying = localState == .playing
    }

    private func didReachEnd(_ item: AVPlayerItem) {
        guard kind == .local, item === player.currentItem,
              !endedCurrentItem, !currentItemFailed else { return }
        refreshLocalObservation()
        guard item === player.currentItem, !currentItemFailed else { return }
        endedCurrentItem = true
        if wantsPlayback && videoIndex + 1 < videos.count {
            videoIndex += 1
            loadCurrentVideo()
        } else {
            wantsPlayback = false
            player.pause()
            refreshLocalObservation()
            if videoIndex + 1 >= videos.count {
                message = "这一组已看完，再次开播会从第一集开始"
                onEnded?()
            } else {
                message = "本集已结束，再次开播继续下一集"
            }
        }
    }

    func tick() {
        let now = Date()
        defer { lastTick = now }
        guard kind == .story, isPlaying else { return }
        position = min(36, position + now.timeIntervalSince(lastTick))
        if position >= 36 { isPlaying = false; onEnded?() }
    }

    deinit {
        statusObservation?.invalidate()
        playerStatusObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}

struct NativeVideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }
}
