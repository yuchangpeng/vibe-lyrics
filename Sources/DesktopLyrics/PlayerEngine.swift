import Foundation
import AppKit
import Combine

/// 播放引擎：监听 Music.app 切歌通知 + 每秒轮询进度，对外提供插值后的播放时钟。
/// 所有调用都在主线程。
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    @Published private(set) var track: TrackInfo?
    @Published private(set) var isPlaying = false
    @Published private(set) var musicRunning = false

    /// 最近一次切歌通知里带的 Apple Music 目录 ID（歌词引擎精确取词用）
    private(set) var storeHint: (name: String, id: String)?

    private let bridge = MusicBridge()
    private var pollTimer: Timer?
    private var tickCount = 0

    // 插值时钟基准：最近一次从 Music 读到的进度及读取时刻
    private var basePosition: Double = 0
    private var baseDate = Date()
    private var backwardStreak = 0

    /// 校准时钟：播放中读数轻微滞后（量化/通讯抖动）时不回跳——时钟只进不退；
    /// 连续 3 次读到更早的进度才认为是真的往回拖了。
    private func syncClock(to polled: Double, at date: Date, playing: Bool) {
        let predicted = currentPosition(at: date)
        let diff = polled - predicted
        if playing, diff < 0, diff > -0.6 {
            backwardStreak += 1
            if backwardStreak < 3 { return }
        }
        backwardStreak = 0
        if playing && abs(diff) > 0.35 {
            DebugLog.log("[引擎] 进度校准 \(String(format: "%+.2f", diff))s")
        }
        basePosition = polled
        baseDate = date
    }

    private init() {}

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        let timer = Timer.scheduledTimer(
            timeInterval: 1.0, target: self, selector: #selector(pollTick),
            userInfo: nil, repeats: true
        )
        timer.tolerance = 0.2
        pollTimer = timer

        DebugLog.log("[引擎] 已启动，Music 运行中：\(bridge.isMusicRunning ? "是" : "否")")
        // 首次快照放到下一个 runloop：先让 UI 出来，再触发「控制音乐」授权弹窗
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// 当前播放进度（插值后），UI 按需高频调用
    func currentPosition(at date: Date = Date()) -> Double {
        var pos = basePosition
        if isPlaying { pos += date.timeIntervalSince(baseDate) }
        if let duration = track?.duration, duration > 0 { pos = min(pos, duration) }
        return max(0, pos)
    }

    @objc private func playerInfoChanged(_ note: Notification) {
        let state = (note.userInfo?["Player State"] as? String) ?? "?"
        DebugLog.log("[引擎] playerInfo 通知：\(state)，曲目：\((note.userInfo?["Name"] as? String) ?? "?")")
        // Apple Music 流媒体曲目的 Store URL 里带目录 ID（i= 参数）
        if let urlString = note.userInfo?["Store URL"] as? String,
           let comps = URLComponents(string: urlString),
           let songID = comps.queryItems?.first(where: { $0.name == "i" })?.value,
           let name = note.userInfo?["Name"] as? String {
            storeHint = (name: name, id: songID)
            DebugLog.log("[引擎] Store URL 目录 id=\(songID)")
        }
        refresh()
    }

    @objc private func pollTick() {
        guard bridge.isMusicRunning else {
            if musicRunning || track != nil { setStopped() }
            return
        }
        tickCount += 1
        // 每 5 秒做一次全量快照兜底（万一通知丢了）；平时只校准进度
        if tickCount % 5 == 0 {
            refresh()
            return
        }
        let before = Date()
        guard let polled = bridge.playerPosition() else { return }
        let after = Date()
        // 读数在通讯途中会变旧，按往返时间的一半补偿
        let compensated = polled + (isPlaying ? after.timeIntervalSince(before) / 2 : 0)
        syncClock(to: compensated, at: after, playing: isPlaying)
    }

    /// 全量刷新：状态 + 曲目 + 进度
    func refresh() {
        guard let snap = bridge.snapshot() else {
            setStopped()
            return
        }
        musicRunning = true
        let playing = snap.state == .playing || snap.state == .fastForwarding || snap.state == .rewinding
        if playing != isPlaying {
            isPlaying = playing
            DebugLog.log("[引擎] 播放状态：\(playing ? "播放" : "暂停")（pos=\(String(format: "%.1f", snap.position))）")
        }
        if snap.track == track {
            syncClock(to: snap.position, at: Date(), playing: playing)
        } else {
            basePosition = snap.position
            baseDate = Date()
            backwardStreak = 0
        }
        if snap.track != track {
            track = snap.track
            if let t = snap.track {
                DebugLog.log("[引擎] 当前曲目：\(t.name) — \(t.artist)（\(Int(t.duration)) 秒）")
            } else {
                DebugLog.log("[引擎] 无当前曲目（状态 \(snap.state.rawValue)）")
            }
        }
    }

    private func setStopped() {
        musicRunning = bridge.isMusicRunning
        isPlaying = false
        if track != nil { track = nil }
        basePosition = 0
        baseDate = Date()
    }
}
