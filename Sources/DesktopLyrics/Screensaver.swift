import SwiftUI
import AppKit
import Combine

// MARK: - 封面存取（屏保背景/封面卡用，按曲目缓存）

@MainActor
final class ArtworkStore: ObservableObject {
    static let shared = ArtworkStore()

    @Published private(set) var image: NSImage?
    /// 版本号：驱动新旧封面/背景交叉淡化
    @Published private(set) var version = 0
    private var loadedKey: String?
    private var pendingKey: String?

    private init() {}

    func refresh(for track: TrackInfo) {
        let key = "\(track.id)|\(track.name)"
        // 成功才记入 loadedKey；失败会清掉 pendingKey，下一秒的 tick 自动重试
        guard key != loadedKey, key != pendingKey else { return }
        pendingKey = key
        Task { [weak self] in
            // 目录 ID：歌词引擎的缓存索引 → 切歌通知里的 Store URL（引擎还没解析完时的快路）
            var songID = LyricsEngine.shared.cachedSongID(for: track)
            if songID == nil, let hint = PlayerEngine.shared.storeHint, hint.name == track.name {
                songID = hint.id
            }
            guard let songID,
                  let url = try? await AppleMusicAPI.shared.artworkURL(songID: songID),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else {
                await MainActor.run {
                    guard let self, self.pendingKey == key else { return }
                    self.pendingKey = nil
                }
                return
            }
            await MainActor.run {
                guard let self, self.pendingKey == key else { return }
                self.pendingKey = nil
                self.loadedKey = key
                self.image = img
                self.version += 1
                DebugLog.log("[屏保] 封面已更新：\(track.name)")
            }
        }
    }
}

// MARK: - 屏保控制器：闲置 60 秒且在播放时进入，任何键鼠输入退出

@MainActor
final class ScreensaverController: ObservableObject {
    static let shared = ScreensaverController()

    @Published private(set) var isActive = false

    private var window: NSWindow?
    private var timer: Timer?
    private var clickMonitor: Any?

    private init() {}

    func start() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.3
        self.timer = timer
    }

    /// 距上次任何键鼠输入的秒数（系统接口，无需权限）
    private var idleSeconds: Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "screensaverEnabled") as? Bool ?? true
    }

    private var threshold: Double {
        let v = UserDefaults.standard.double(forKey: "screensaverIdleSeconds")
        return v > 0 ? v : 60
    }

    private func tick() {
        if isActive {
            // 任何输入、音乐没了 → 退出
            if idleSeconds < 1 || !PlayerEngine.shared.musicRunning || PlayerEngine.shared.track == nil {
                hide()
            } else if let track = PlayerEngine.shared.track {
                ArtworkStore.shared.refresh(for: track) // 屏保期间切歌，换封面
            }
            return
        }
        guard enabled,
              PlayerEngine.shared.isPlaying,
              PlayerEngine.shared.track != nil,
              idleSeconds >= threshold else { return }
        show()
    }

    private func show() {
        guard let screen = NSScreen.main else { return }
        if let track = PlayerEngine.shared.track {
            ArtworkStore.shared.refresh(for: track)
        }

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ScreensaverView(screen: screen.frame.size))
        win.contentView = hosting
        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.8
            win.animator().alphaValue = 1
        }
        window = win
        isActive = true
        NSCursor.setHiddenUntilMouseMoves(true)
        // 点击立即退出（不等下一秒的轮询）
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            Task { @MainActor in self?.hide() }
            return event
        }
        DebugLog.log("[屏保] 进入（闲置 \(Int(threshold))s）")
    }

    private func hide() {
        guard isActive, let win = window else { return }
        isActive = false
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            win.animator().alphaValue = 0
        }, completionHandler: {
            win.orderOut(nil)
        })
        window = nil
        DebugLog.log("[屏保] 退出")
    }
}

// MARK: - 屏保画面：分享卡构图 + 实时歌词动效

struct ScreensaverView: View {
    let screen: CGSize

    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var lyricsEngine = LyricsEngine.shared
    @ObservedObject private var artwork = ArtworkStore.shared

    @AppStorage("lyricsOffset") private var lyricsOffset: Double = 0.12
    @AppStorage("showTranslation") private var showTranslation = true
    @AppStorage("lyricTint") private var tintRaw = LyricTint.white.rawValue

    @State private var revealed = false

    private var tint: Color { (LyricTint(rawValue: tintRaw) ?? .white).color }
    private let fontSize: CGFloat = 46
    private var lineHeight: CGFloat { fontSize * 2.55 }
    private var translationHeight: CGFloat { fontSize * 0.95 }
    private var nextHeight: CGFloat { fontSize * 1.25 }
    private var coverSize: CGFloat { min(screen.width * 0.27, screen.height * 0.44) }
    private var lyricMaxWidth: CGFloat { screen.width - coverSize - 260 }

    var body: some View {
        ZStack {
            background
                .opacity(revealed ? 1 : 0)
                .animation(.easeOut(duration: 0.9), value: revealed)
            HStack(spacing: 0) {
                leftColumn
                    .frame(width: coverSize + 40)
                rightLyrics
                    .padding(.leading, 70)
                Spacer(minLength: 0)
            }
            .padding(.leading, screen.width * 0.07)
            .padding(.trailing, 50)
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 28)
            .scaleEffect(revealed ? 1 : 0.985)
            .animation(.easeOut(duration: 1.05).delay(0.2), value: revealed)
        }
        .frame(width: screen.width, height: screen.height)
        .clipped()
        .overlay(alignment: .topTrailing) {
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                Text(Date(), format: .dateTime.hour().minute())
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
            .padding(.top, 34)
            .padding(.trailing, 44)
            .opacity(revealed ? 1 : 0)
            .animation(.easeOut(duration: 0.8).delay(0.5), value: revealed)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("♪ Vibe Lyrics")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.trailing, 44)
                .padding(.bottom, 30)
                .opacity(revealed ? 1 : 0)
                .animation(.easeOut(duration: 0.8).delay(0.5), value: revealed)
        }
        .onAppear {
            DispatchQueue.main.async { revealed = true }
        }
    }

    // MARK: 背景

    @ViewBuilder
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.13, blue: 0.17), Color(red: 0.04, green: 0.04, blue: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            if let img = artwork.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: screen.width, height: screen.height)
                    .scaleEffect(1.4)
                    .blur(radius: 100)
                    .saturation(1.5)
                    .id(artwork.version)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.9), value: artwork.version)
        .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.45), location: 0),
                            .init(color: .black.opacity(0.2), location: 0.55),
                            .init(color: .black.opacity(0.42), location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
    }

    // MARK: 左列（封面卡 + 歌名歌手）

    private var leftColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                coverCard
                coverBase
                    .scaleEffect(x: 1, y: -1)
                    .mask(LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.28), location: 0),
                            .init(color: .clear, location: 0.3),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(height: 0, alignment: .top)
            }
            .rotationEffect(.degrees(-2.5))
            .id(artwork.version)
            .transition(.opacity)
            if let track = player.track {
                VStack(spacing: 8) {
                    Text(track.name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .padding(.top, 40)
                .id("meta-\(track.id)|\(track.name)")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: artwork.version)
        .animation(.easeInOut(duration: 0.5), value: player.track)
    }

    private var coverCard: some View {
        coverBase
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 46, y: 20)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    @ViewBuilder
    private var coverBase: some View {
        Group {
            if let img = artwork.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.22, green: 0.23, blue: 0.28), Color(red: 0.1, green: 0.11, blue: 0.14)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Text("♪")
                        .font(.system(size: coverSize * 0.4, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: 右侧（实时歌词，完整动效）

    private var songKey: String {
        player.track.map { "\($0.id)|\($0.name)" } ?? "none"
    }

    private var rightLyrics: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            ZStack {
                liveLyrics(at: context.date)
                    .id(songKey)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.5), value: songKey)
        }
    }

    @ViewBuilder
    private func liveLyrics(at date: Date) -> some View {
        if case .ready(let lyrics) = lyricsEngine.status {
            let position = player.currentPosition(at: date) + lyricsOffset
            let index = lyrics.currentIndex(at: position)
            let translationOn = showTranslation && lyrics.hasTranslation
            let scrollDistance = (lineHeight + nextHeight) / 2 + (translationOn ? translationHeight : 0)
            VStack(spacing: 0) {
                ZStack {
                    if let index {
                        let line = lyrics.lines[index]
                        Group {
                            if let words = line.words, !words.isEmpty {
                                KaraokeLine(
                                    words: words, lineBegin: line.begin, position: position,
                                    fontSize: fontSize, tint: tint, maxWidth: lyricMaxWidth
                                )
                            } else {
                                bigLine(line.text, size: fontSize, opacity: 0.95)
                            }
                        }
                        .id(index)
                        .transition(.riseIn(from: scrollDistance))
                    }
                }
                .frame(height: lineHeight)
                if translationOn {
                    ZStack {
                        if let index, let translation = lyrics.lines[index].translation {
                            bigLine(translation, size: fontSize * 0.5, opacity: 0.6)
                                .id("tr-\(index)")
                                .transition(.opacity)
                        }
                    }
                    .frame(height: translationHeight)
                }
                ZStack {
                    if let next = nextPreview(lyrics, index: index, position: position) {
                        bigLine(next.text, size: fontSize * 0.5, opacity: 0.5)
                            .opacity(next.reveal)
                            .offset(y: 10 * (1 - next.reveal))
                            .id(next.id)
                            .transition(.opacity)
                    }
                }
                .frame(height: nextHeight)
            }
            .animation(.easeOut(duration: 0.4), value: index)
            .frame(width: lyricMaxWidth)
        } else if let track = player.track {
            bigLine("♪ \(track.name)", size: fontSize * 0.6, opacity: 0.5)
        }
    }

    private func nextPreview(_ lyrics: Lyrics, index: Int?, position: Double) -> (id: Int, text: String, reveal: Double)? {
        let next = (index ?? -1) + 1
        guard next < lyrics.lines.count else { return nil }
        var reveal = 1.0
        if let index {
            let line = lyrics.lines[index]
            let midpoint = line.end > line.begin
                ? line.begin + (line.end - line.begin) * 0.5
                : line.begin + 2
            reveal = OverlayView.smoothstep((position - midpoint) / 0.6)
            guard reveal > 0.001 else { return nil }
        }
        return (next, lyrics.lines[next].text, reveal)
    }

    /// 三层阴影文字（逐行歌词/翻译/预告用），与桌面歌词同一视觉语言
    private func bigLine(_ text: String, size: CGFloat, opacity: Double) -> some View {
        let font = Font.system(size: size, weight: .bold, design: .rounded)
        func copy(_ color: Color) -> some View {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: lyricMaxWidth, alignment: .center)
        }
        return ZStack {
            copy(.black.opacity(0.3)).blur(radius: 8)
            copy(.black.opacity(0.5)).offset(y: 1).blur(radius: 2.5)
            copy(tint.opacity(opacity))
        }
    }
}
