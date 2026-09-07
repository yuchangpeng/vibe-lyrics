import Foundation
import AppKit
import ScriptingBridge

/// Music.app 播放状态（AppleEvent 四字码）
enum MusicPlayerState: UInt32 {
    case stopped = 0x6b50_5353        // 'kPSS'
    case playing = 0x6b50_5350        // 'kPSP'
    case paused = 0x6b50_5370         // 'kPSp'
    case fastForwarding = 0x6b50_5346 // 'kPSF'
    case rewinding = 0x6b50_5352      // 'kPSR'
}

struct TrackInfo: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    /// 秒
    var duration: Double
}

struct PlayerSnapshot {
    var state: MusicPlayerState
    var position: Double
    var track: TrackInfo?
}

// ScriptingBridge 没有 Swift 头文件，用 @objc 协议 + 动态派发声明需要的属性
@objc private protocol MusicTrackSB {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Double { get }
    @objc optional var persistentID: String { get }
}

@objc private protocol MusicAppSB {
    @objc optional var playerPosition: Double { get }
    @objc optional var playerState: UInt32 { get }
    @objc optional var currentTrack: MusicTrackSB { get }
}

extension SBApplication: MusicAppSB {}
extension SBObject: MusicTrackSB {}

/// 与 Music.app 的所有通信都收口在这里
final class MusicBridge {
    static let musicBundleID = "com.apple.Music"

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).isEmpty
    }

    private var cachedApp: SBApplication?

    // Music 未运行时绝不创建 SB 对象——访问属性会把 Music 拉起来
    private var sbApp: MusicAppSB? {
        guard isMusicRunning else {
            cachedApp = nil
            return nil
        }
        if cachedApp == nil {
            cachedApp = SBApplication(bundleIdentifier: Self.musicBundleID)
        }
        return cachedApp
    }

    /// 只读播放进度（每秒轮询用，最轻量）
    func playerPosition() -> Double? {
        sbApp?.playerPosition
    }

    /// 跳转播放位置（双击歌词回到本句用）
    func seek(to seconds: Double) {
        guard let app = sbApp as? NSObject else { return }
        app.setValue(seconds, forKey: "playerPosition")
    }

    /// 全量快照：状态 + 进度 + 当前曲目
    func snapshot() -> PlayerSnapshot? {
        guard let app = sbApp else { return nil }
        let state = app.playerState.flatMap(MusicPlayerState.init(rawValue:)) ?? .stopped
        let position = app.playerPosition ?? 0
        var track: TrackInfo?
        if state != .stopped, let t = app.currentTrack, let name = t.name, !name.isEmpty {
            track = TrackInfo(
                id: t.persistentID ?? "",
                name: name,
                artist: t.artist ?? "",
                album: t.album ?? "",
                duration: t.duration ?? 0
            )
        }
        return PlayerSnapshot(state: state, position: position, track: track)
    }
}
