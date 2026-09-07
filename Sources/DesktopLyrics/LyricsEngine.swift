import Foundation
import Combine

/// 歌词引擎：跟随播放曲目取词（本地缓存 → Apple 官方 TTML）并对外发布
final class LyricsEngine: ObservableObject {
    static let shared = LyricsEngine()

    enum Status: Equatable {
        case idle          // 无曲目
        case loading
        case ready(Lyrics)
        case unavailable   // 这首歌没有歌词
        case needsLogin
    }

    @Published private(set) var status: Status = .idle

    private var bag = Set<AnyCancellable>()
    private var fetchTask: Task<Void, Never>?
    private var didAutoPromptLogin = false

    private let fm = FileManager.default
    private lazy var supportDir: URL = {
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DesktopLyrics")
        try? fm.createDirectory(at: dir.appendingPathComponent("lyrics"), withIntermediateDirectories: true)
        return dir
    }()
    private lazy var idIndexURL = supportDir.appendingPathComponent("track-ids.json")
    private var idIndex: [String: String] = [:]

    private init() {
        if let data = try? Data(contentsOf: idIndexURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            idIndex = dict
        }
    }

    func start() {
        AppleMusicAuth.shared.onLogin = { [weak self] in self?.refetchCurrent() }
        // 切歌瞬间先清状态
        PlayerEngine.shared.$track
            .removeDuplicates()
            .sink { [weak self] track in
                self?.fetchTask?.cancel()
                self?.status = track == nil ? .idle : .loading
            }
            .store(in: &bag)
        // 停稳 350ms 再取词（快速跳歌防抖）
        PlayerEngine.shared.$track
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] track in
                guard let track else { return }
                self?.fetch(track)
            }
            .store(in: &bag)
    }

    /// 清掉本曲缓存并重新取词（菜单里用）
    func refetchCurrent() {
        guard let track = PlayerEngine.shared.track else { return }
        if let songID = idIndex[key(for: track)] {
            try? fm.removeItem(at: cacheURL(songID: songID, ext: "ttml"))
            try? fm.removeItem(at: cacheURL(songID: songID, ext: "none"))
        }
        fetch(track)
    }

    private func key(for t: TrackInfo) -> String {
        t.id.isEmpty ? "\(t.name)|\(t.artist)|\(t.album)" : t.id
    }

    private func cacheURL(songID: String, ext: String) -> URL {
        supportDir.appendingPathComponent("lyrics/\(songID).\(ext)")
    }

    private func fetch(_ track: TrackInfo) {
        fetchTask?.cancel()
        status = .loading
        fetchTask = Task { [weak self] in
            guard let self else { return }
            let newStatus = await self.resolve(track)
            guard !Task.isCancelled, PlayerEngine.shared.track == track else { return }
            await MainActor.run {
                self.status = newStatus
                // 第一次遇到「需要登录」时自动弹登录窗，之后只在菜单里提示
                if case .needsLogin = newStatus, !self.didAutoPromptLogin {
                    self.didAutoPromptLogin = true
                    AppleMusicAuth.shared.showLogin()
                }
            }
        }
    }

    private func resolve(_ track: TrackInfo) async -> Status {
        do {
            // 1. 曲目 → Apple 目录 ID：缓存索引 → 切歌通知里的 Store URL → 搜索兜底
            var songID = idIndex[key(for: track)]
            if songID == nil, let hint = PlayerEngine.shared.storeHint, hint.name == track.name {
                songID = hint.id
                DebugLog.log("[歌词] 从 Store URL 拿到曲目 id=\(hint.id)")
            }
            if songID == nil {
                songID = try await AppleMusicAPI.shared.searchSongID(
                    name: track.name, artist: track.artist,
                    album: track.album, duration: track.duration
                )
            }
            guard let songID else {
                DebugLog.log("[歌词] 找不到曲目目录 ID：\(track.name)")
                return .unavailable
            }
            saveIDIndex(key: key(for: track), songID: songID)

            // 2. 磁盘缓存
            let ttmlURL = cacheURL(songID: songID, ext: "ttml")
            let noneURL = cacheURL(songID: songID, ext: "none")
            if let cached = try? String(contentsOf: ttmlURL, encoding: .utf8),
               let lyrics = TTMLParser.parse(cached) {
                DebugLog.log("[歌词] 命中缓存：\(track.name)（\(lyrics.lines.count) 行，逐字=\(lyrics.wordTimed)，翻译=\(lyrics.lines.filter { $0.translation != nil }.count) 行）")
                return .ready(lyrics)
            }
            if fm.fileExists(atPath: noneURL.path) { return .unavailable }

            // 3. 在线取词
            guard let ttml = try await AppleMusicAPI.shared.lyricsTTML(songID: songID) else {
                try? Data().write(to: noneURL) // 记住「无词」，避免每次重复请求
                DebugLog.log("[歌词] Apple 没有这首的歌词：\(track.name)")
                return .unavailable
            }
            try? ttml.data(using: .utf8)?.write(to: ttmlURL)
            guard let lyrics = TTMLParser.parse(ttml) else {
                DebugLog.log("[歌词] TTML 解析失败：\(track.name)")
                return .unavailable
            }
            DebugLog.log("[歌词] 已取到：\(track.name)（\(lyrics.lines.count) 行，逐字=\(lyrics.wordTimed)，翻译=\(lyrics.lines.filter { $0.translation != nil }.count) 行）")
            return .ready(lyrics)
        } catch AMError.needsLogin {
            return .needsLogin
        } catch {
            DebugLog.log("[歌词] 取词失败：\(error)")
            return .unavailable
        }
    }

    private func saveIDIndex(key: String, songID: String) {
        guard idIndex[key] != songID else { return }
        idIndex[key] = songID
        if let data = try? JSONEncoder().encode(idIndex) {
            try? data.write(to: idIndexURL)
        }
    }
}
