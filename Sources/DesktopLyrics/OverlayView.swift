import SwiftUI
import AppKit

/// 桌面歌词：纯文字、微透、无边框；换行以「向上滚动一格」接力。
///
/// 渲染铁律（血泪教训）：
/// 1. 不用 .shadow —— 它挂在文字大小的图层上向外画，动画合成时会被贴字裁剪；
///    阴影一律用「黑色模糊副本垫底」画成普通内容（辉光同理）。
/// 2. 模糊/阴影副本都放在带内边距的容器里，先 padding 后 blur，永不越界。
/// 3. 不用 GeometryReader（退场动画期间会塌陷）；排版用固定窗宽预测量字号。
/// 4. 槽位高度只随设置变化，不随歌曲内容变化，版面永不跳动。
struct OverlayView: View {
    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var lyricsEngine = LyricsEngine.shared

    @AppStorage("lyricsOffset") private var lyricsOffset: Double = 0.12
    @AppStorage("fontSize") private var fontSize: Double = 32
    @AppStorage("showPreview") private var showPreview = true
    @AppStorage("showTranslation") private var showTranslation = true
    @AppStorage("lyricTint") private var tintRaw = LyricTint.white.rawValue

    private var tint: Color { (LyricTint(rawValue: tintRaw) ?? .white).color }
    private var lineHeight: CGFloat { fontSize * 2.9 }
    private var translationHeight: CGFloat { fontSize * 0.95 }
    private var nextHeight: CGFloat { fontSize * 1.25 }
    /// 滚动换行的行程：预告句中心到主句中心的距离
    private var scrollDistance: CGFloat {
        (lineHeight + nextHeight) / 2 + (showTranslation ? translationHeight : 0)
    }

    /// 刷新率：逐字 60fps（动画平滑），逐行 30fps，暂停 10fps
    private var tickInterval: Double {
        guard case .ready(let lyrics) = lyricsEngine.status, player.isPlaying else { return 0.1 }
        return lyrics.wordTimed ? 1.0 / 60.0 : 1.0 / 30.0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: tickInterval, paused: false)) { context in
            content(at: context.date)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 开场卡窗口期：切歌后前 2.2 秒
    private func introActive(at date: Date) -> Bool {
        player.track != nil && date.timeIntervalSince(player.trackChangedAt) < 2.2
    }

    /// 状态标识：曲目、歌词状态或开场卡阶段变化时，整块内容做柔和交叉过渡
    private func statusKey(at date: Date) -> String {
        let trackKey = player.track.map { "\($0.id)|\($0.name)" } ?? "none"
        let phase = introActive(at: date) ? "#intro" : ""
        switch lyricsEngine.status {
        case .ready: return trackKey + phase + "#ready"
        case .loading: return trackKey + phase + "#loading"
        case .unavailable: return trackKey + phase + "#unavailable"
        case .needsLogin: return trackKey + "#login"
        case .idle: return trackKey + "#idle"
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        ZStack {
            if let track = player.track {
                if introActive(at: date), lyricsEngine.status != .idle, lyricsEngine.status != .needsLogin {
                    introCard(track)
                        .id("intro-\(track.id)|\(track.name)")
                        .transition(.statusSwap)
                } else {
                switch lyricsEngine.status {
                case .ready(let lyrics):
                    lyricsView(lyrics, at: date)
                        .id(statusKey(at: date))
                        .transition(.statusSwap)
                case .needsLogin:
                    hint("需要连接 Apple Music 账号才能显示歌词 — 点菜单栏 ♪ 图标")
                        .transition(.statusSwap)
                case .unavailable:
                    hint("♪ \(track.name) — \(track.artist)")
                        .transition(.statusSwap)
                case .idle, .loading:
                    EmptyView()
                }
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: statusKey(at: date))
    }

    /// 切歌开场卡：歌名 + 歌手，两秒后交给歌词
    private func introCard(_ track: TrackInfo) -> some View {
        VStack(spacing: 8) {
            layeredText(track.name, size: fontSize * 0.85, weight: .bold, textOpacity: 0.95,
                        hPad: 28, vPad: 8, minScale: 0.5, crispBlur: 2, wideBlur: 6)
            layeredText(track.artist, size: fontSize * 0.45, weight: .semibold, textOpacity: 0.55,
                        hPad: 28, vPad: 4, minScale: 0.6, crispBlur: 1.5, wideBlur: 4,
                        crispOpacity: 0.2, wideOpacity: 0.2)
        }
    }

    private func lyricsView(_ lyrics: Lyrics, at date: Date) -> some View {
        let position = player.currentPosition(at: date) + lyricsOffset
        let index = lyrics.currentIndex(at: position)
        return VStack(spacing: 0) {
            // 主句槽位（高度恒定）
            ZStack {
                if let index {
                    let line = lyrics.lines[index]
                    Group {
                        if let words = line.words, !words.isEmpty {
                            KaraokeLine(
                                words: words, lineBegin: line.begin, position: position,
                                fontSize: fontSize, tint: tint
                            )
                        } else {
                            mainLine(line.text)
                        }
                    }
                    .id(index)
                    .transition(.riseIn(from: scrollDistance))
                }
            }
            .frame(height: lineHeight)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // 双击：回到本句开头重唱
                if let index {
                    PlayerEngine.shared.seek(to: max(0, lyrics.lines[index].begin - 0.1))
                }
            }
            // 翻译槽位（开关控制，高度恒定）
            if showTranslation {
                ZStack {
                    if let index, let translation = lyrics.lines[index].translation {
                        translationLine(translation)
                            .id("tr-\(index)")
                            .transition(.opacity)
                    }
                }
                .frame(height: translationHeight)
            }
            // 预告句槽位（高度恒定）
            ZStack {
                if showPreview, let next = nextEntry(lyrics, index: index, position: position) {
                    nextLine(next.text)
                        .opacity(next.reveal)
                        .offset(y: 8 * (1 - next.reveal))
                        .id(next.id)
                        .transition(.opacity)
                }
            }
            .frame(height: nextHeight)
        }
        .animation(.easeOut(duration: 0.4), value: index)
        .onChange(of: index) { _, newIndex in
            reportMetrics(lyrics, index: newIndex)
        }
        .onAppear {
            reportMetrics(lyrics, index: index)
        }
    }

    /// 向窗口控制器汇报当前文字宽度（智能穿透用：只有文字附近可点击）
    private func reportMetrics(_ lyrics: Lyrics, index: Int?) {
        let text = index.map { lyrics.lines[$0].text } ?? lyrics.lines.first?.text ?? ""
        let natural = TextMeasure.width(of: text, size: fontSize)
        let width = min(natural, PanelController.shared.panelWidth - 56)
        PanelController.shared.updateContentMetrics(
            fontSize: fontSize, showTranslation: showTranslation, textWidth: width
        )
    }

    /// 下一句预告：当前句唱到后半段，用 0.6s 从下方缓缓淡入（前奏期间直接预告第一句）
    private func nextEntry(_ lyrics: Lyrics, index: Int?, position: Double) -> (id: Int, text: String, reveal: Double)? {
        let next = (index ?? -1) + 1
        guard next < lyrics.lines.count else { return nil }
        var reveal = 1.0
        if let index {
            let line = lyrics.lines[index]
            let midpoint = line.end > line.begin
                ? line.begin + (line.end - line.begin) * 0.5
                : line.begin + 2
            reveal = Self.smoothstep((position - midpoint) / 0.6)
            guard reveal > 0.001 else { return nil }
        }
        return (next, lyrics.lines[next].text, reveal)
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// 三层文字：宽黑影（氛围）→ 紧黑影（描边感）→ 染色正文。
    /// 阴影是内容不是特效，任何合成时机都不会被裁。
    private func layeredText(
        _ text: String, size: CGFloat, weight: Font.Weight, textOpacity: Double,
        hPad: CGFloat, vPad: CGFloat, minScale: CGFloat,
        crispBlur: CGFloat, wideBlur: CGFloat,
        crispOpacity: Double = 0.5, wideOpacity: Double = 0.3
    ) -> some View {
        let font = Font.system(size: size, weight: weight, design: .rounded)
        func copy(_ color: Color) -> some View {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(minScale)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
        }
        return ZStack {
            copy(.black.opacity(wideOpacity)).blur(radius: wideBlur)
            copy(.black.opacity(crispOpacity)).offset(y: 1).blur(radius: crispBlur)
            copy(tint.opacity(textOpacity))
        }
        .frame(maxWidth: .infinity)
    }

    private func mainLine(_ text: String) -> some View {
        layeredText(text, size: fontSize, weight: .bold, textOpacity: 0.92,
                    hPad: 28, vPad: fontSize * 0.44, minScale: 0.5, crispBlur: 2.5, wideBlur: 7)
    }

    private func translationLine(_ text: String) -> some View {
        layeredText(text, size: fontSize * 0.5, weight: .semibold, textOpacity: 0.6,
                    hPad: 28, vPad: 4, minScale: 0.6, crispBlur: 1.5, wideBlur: 4,
                    crispOpacity: 0.15, wideOpacity: 0.2)
    }

    private func nextLine(_ text: String) -> some View {
        layeredText(text, size: fontSize * 0.53, weight: .semibold, textOpacity: 0.55,
                    hPad: 28, vPad: 8, minScale: 0.6, crispBlur: 1.5, wideBlur: 4,
                    crispOpacity: 0.12, wideOpacity: 0.2)
    }

    private func hint(_ text: String) -> some View {
        layeredText(text, size: 14, weight: .medium, textOpacity: 0.5,
                    hPad: 16, vPad: 8, minScale: 0.8, crispBlur: 1.5, wideBlur: 4)
    }
}

// MARK: - 逐字卡拉OK（雾聚拢 + 波浪浮沉 + 瀑布入场 + 整行辉光）

/// 一行逐字歌词。五层同构渲染，全部按播放时钟的纯函数驱动。
private struct KaraokeLine: View {
    let words: [LyricWord]
    let lineBegin: Double
    let position: Double
    let fontSize: Double
    let tint: Color

    private static var sizeCache: [String: CGFloat] = [:]

    private enum RowStyle {
        case wideShadow   // 氛围软影（唱到后浮现）
        case crispShadow  // 描边影（唱到后浮现）
        case glow         // 唱到的字的辉光
        case mainBlur     // 未唱：模糊的雾（失焦态）
        case mainSharp    // 聚拢即全亮的清晰字
    }

    var body: some View {
        let fitted = Self.fittedFontSize(
            for: words.map(\.text).joined(),
            maxWidth: max(60, PanelController.shared.panelWidth - 64),
            base: fontSize
        )
        let hPad: CGFloat = 26
        let vPad: CGFloat = fontSize * 0.69
        return ZStack {
            row(.wideShadow, fontSize: fitted)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                .blur(radius: 9)
            row(.crispShadow, fontSize: fitted)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                .offset(y: 1)
                .blur(radius: 2.5)
            row(.glow, fontSize: fitted)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                .blur(radius: 8)
            row(.mainBlur, fontSize: fitted)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                .blur(radius: 2)
            row(.mainSharp, fontSize: fitted)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
            sparkles(fitted: fitted, hPad: hPad)
        }
        .frame(maxWidth: .infinity)
    }

    /// 闪粉：长音（>0.8s）唱到时，字的上方浮起细碎微粒
    private func sparkles(fitted: CGFloat, hPad: CGFloat) -> some View {
        let widths = words.map { TextMeasure.width(of: $0.text, size: fitted) }
        let totalWidth = widths.reduce(0, +) + hPad * 2
        let height = max(60, fontSize * 2.2)
        return Canvas { ctx, size in
            var xCursor = hPad
            for (i, word) in words.enumerated() {
                let w = widths[i]
                defer { xCursor += w }
                let duration = word.end - word.begin
                guard duration > 0.8 else { continue }
                let t = position - word.begin
                guard t > 0.1, t < duration + 0.4 else { continue }
                let centerX = xCursor + w / 2
                let baseY = size.height / 2 - fitted * 0.15
                var rng = UInt64(i &* 2654435761 &+ 97)
                func rand() -> Double {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    return Double(rng >> 33 % 1000) / 1000
                }
                for particle in 0..<14 {
                    let r1 = rand(), r2 = rand(), r3 = rand()
                    let cycle = 0.9 + r1 * 0.7
                    let birth = 0.1 + Double(particle) * 0.08 + r2 * 0.25
                    guard t > birth else { continue }
                    let age = (t - birth).truncatingRemainder(dividingBy: cycle)
                    let life = age / cycle
                    let x = centerX + (r3 - 0.5) * w * 0.95 + sin((t + r2 * 7) * 2.6) * 2.5
                    let y = baseY - life * (12 + r1 * 16)
                    let fade = sin(life * .pi)
                    let dot = 1.1 + r2 * 1.7
                    let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    ctx.fill(Ellipse().path(in: rect), with: .color(tint.opacity(0.85 * fade)))
                }
            }
        }
        .frame(width: totalWidth, height: height)
        .allowsHitTesting(false)
    }

    private func row(_ style: RowStyle, fontSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(words.indices, id: \.self) { i in
                let word = words[i]
                let active = activeness(word)
                let entry = entrance(index: i)
                wordText(word, style: style, fontSize: fontSize, active: active)
                    .opacity(entry)
                    .offset(y: -3.4 * active + 10 * (1 - entry))
            }
        }
    }

    @ViewBuilder
    private func wordText(_ word: LyricWord, style: RowStyle, fontSize: CGFloat, active: Double) -> some View {
        let font = Font.system(size: fontSize, weight: .bold, design: .rounded)
        let focus = focus(word)
        switch style {
        case .wideShadow:
            Text(word.text).font(font).foregroundStyle(.black.opacity(0.3))
                .opacity(focus)
        case .crispShadow:
            Text(word.text).font(font).foregroundStyle(.black.opacity(0.5))
                .opacity(focus)
        case .glow:
            Text(word.text).font(font).foregroundStyle(tint)
                .opacity(0.65 * active)
        case .mainBlur:
            Text(word.text).font(font).foregroundStyle(tint.opacity(0.5))
                .opacity(1 - focus)
        case .mainSharp:
            Text(word.text).font(font).foregroundStyle(tint)
                .opacity(focus)
        }
    }

    /// 对焦程度：快唱到前 0.45 秒开始聚拢，聚拢完成即全亮——
    /// 雾直接凝成亮字，不存在「清晰但半暗」的中间态
    private func focus(_ word: LyricWord) -> Double {
        smoothstep((position - word.begin + 0.45) / 0.45)
    }

    /// 按整行文字宽度算出不越界的字号（结果缓存，每行只算一次）
    private static func fittedFontSize(for text: String, maxWidth: CGFloat, base: Double) -> CGFloat {
        let key = "\(Int(base))|\(Int(maxWidth))|\(text)"
        if let cached = sizeCache[key] { return cached }
        let width = TextMeasure.width(of: text, size: base)
        let size = width > maxWidth ? max(14, base * maxWidth / width) : base
        if sizeCache.count > 500 { sizeCache.removeAll() }
        sizeCache[key] = size
        return size
    }

    /// 瀑布入场：换行后每个字依次延迟 40ms，用 0.35s 从下方浮起淡入
    private func entrance(index: Int) -> Double {
        smoothstep((position - lineBegin + 0.12 - Double(index) * 0.04) / 0.35)
    }

    /// 词内演唱进度 0..1
    private func progress(_ word: LyricWord) -> Double {
        guard word.end > word.begin else { return position >= word.begin ? 1 : 0 }
        return min(1, max(0, (position - word.begin) / (word.end - word.begin)))
    }

    private func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// 更柔的缓动（两端加速度也连续），起落不发僵
    private func smootherstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// 波浪包络：0.35s 缓缓浮起后随即缓缓落下（0.8s），不在顶部停留
    private func activeness(_ word: LyricWord) -> Double {
        let t = position - word.begin
        if t < 0 { return 0 }
        let rise = 0.35
        let fall = 0.8
        if t <= rise { return smootherstep(t / rise) }
        return smootherstep(1 - (t - rise) / fall)
    }
}

// MARK: - 文字测量

/// 统一的文字宽度测量（bold rounded 字体，带缓存）
enum TextMeasure {
    private static var cache: [String: CGFloat] = [:]

    static func width(of text: String, size: CGFloat) -> CGFloat {
        let key = "\(Int(size))|\(text)"
        if let cached = cache[key] { return cached }
        let descriptor = NSFont.systemFont(ofSize: size, weight: .bold)
            .fontDescriptor.withDesign(.rounded)
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        if cache.count > 600 { cache.removeAll() }
        cache[key] = width
        return width
    }
}

// MARK: - 过渡动画

private struct LyricTransitionModifier: ViewModifier {
    var opacity: Double
    var y: Double
    var blur: Double
    var scale: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: y)
            .blur(radius: blur)
            .scaleEffect(scale)
    }
}

extension AnyTransition {
    /// 切歌/状态切换：原地虚化淡出、淡入
    static let statusSwap = AnyTransition.modifier(
        active: LyricTransitionModifier(opacity: 0, y: 0, blur: 5, scale: 0.99),
        identity: LyricTransitionModifier(opacity: 1, y: 0, blur: 0, scale: 1)
    )

    /// 换行 = 向上滚动一格：新句从预告句位置完全透明地升入渐显，旧句向上淡出
    static func riseIn(from distance: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: LyricTransitionModifier(opacity: 0, y: distance, blur: 0, scale: 1),
                identity: LyricTransitionModifier(opacity: 1, y: 0, blur: 0, scale: 1)
            ),
            removal: .modifier(
                active: LyricTransitionModifier(opacity: 0, y: -distance * 0.5, blur: 0, scale: 1),
                identity: LyricTransitionModifier(opacity: 1, y: 0, blur: 0, scale: 1)
            )
        )
    }
}
