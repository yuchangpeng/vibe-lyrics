import SwiftUI
import AppKit

/// 桌面歌词：纯文字、微透、无边框；换行时做 Apple 风格的柔和过渡。
///
/// 渲染铁律（血泪教训）：
/// 1. 不用 .shadow —— 它挂在文字大小的图层上向外画，动画合成时会被贴字裁剪；
///    阴影一律用「黑色模糊副本垫底」画成普通内容（辉光同理）。
/// 2. 模糊/阴影副本都放在带内边距的容器里，先 padding 后 blur，永不越界。
/// 3. 排版先测量、算好字号再排，不做越界布局；主/预告句槽位高度固定，版面永不跳动。
struct OverlayView: View {
    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var lyricsEngine = LyricsEngine.shared

    /// 歌词整体时间偏移（秒，正值 = 提前显示）；默认补偿链路延迟
    @AppStorage("lyricsOffset") private var lyricsOffset: Double = 0.12

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

    /// 状态标识：曲目或歌词状态变化时，整块内容做柔和交叉过渡（切歌不硬切）
    private var statusKey: String {
        let trackKey = player.track.map { "\($0.id)|\($0.name)" } ?? "none"
        switch lyricsEngine.status {
        case .ready: return trackKey + "#ready"
        case .loading: return trackKey + "#loading"
        case .unavailable: return trackKey + "#unavailable"
        case .needsLogin: return trackKey + "#login"
        case .idle: return trackKey + "#idle"
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        ZStack {
            if player.track != nil {
                switch lyricsEngine.status {
                case .ready(let lyrics):
                    lyricsView(lyrics, at: date)
                        .id(statusKey)
                        .transition(.statusSwap)
                case .needsLogin:
                    hint("需要连接 Apple Music 账号才能显示歌词 — 点菜单栏 ♪ 图标")
                        .transition(.statusSwap)
                case .unavailable:
                    if let track = player.track {
                        hint("♪ \(track.name) — \(track.artist)")
                            .transition(.statusSwap)
                    }
                case .idle, .loading:
                    EmptyView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: statusKey)
    }

    private func lyricsView(_ lyrics: Lyrics, at date: Date) -> some View {
        let position = player.currentPosition(at: date) + lyricsOffset
        let index = lyrics.currentIndex(at: position)
        return VStack(spacing: 0) {
            // 主句槽位：高度恒定，主句出现/消失时版面不跳动
            ZStack {
                if let index {
                    let line = lyrics.lines[index]
                    Group {
                        if let words = line.words, !words.isEmpty {
                            KaraokeLine(words: words, lineBegin: line.begin, position: position)
                                .transition(.karaokeSwap)
                        } else {
                            mainLine(line.text)
                                .transition(.lyricMain)
                        }
                    }
                    .id(index)
                }
            }
            .frame(height: 94)
            // 预告句槽位：同样恒定
            ZStack {
                if let next = nextEntry(lyrics, index: index, position: position) {
                    nextLine(next.text)
                        .opacity(next.reveal)
                        .offset(y: 8 * (1 - next.reveal))
                        .id(next.id)
                        .transition(.lyricNext)
                }
            }
            .frame(height: 40)
        }
        .animation(.easeOut(duration: 0.4), value: index)
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

    /// 三层文字：宽黑影（氛围）→ 紧黑影（描边感）→ 白色正文。
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
            copy(.white.opacity(textOpacity))
        }
        .frame(maxWidth: .infinity)
    }

    private func mainLine(_ text: String) -> some View {
        layeredText(text, size: 32, weight: .bold, textOpacity: 0.92,
                    hPad: 28, vPad: 14, minScale: 0.5, crispBlur: 2.5, wideBlur: 7)
    }

    private func nextLine(_ text: String) -> some View {
        layeredText(text, size: 17, weight: .semibold, textOpacity: 0.55,
                    hPad: 28, vPad: 8, minScale: 0.6, crispBlur: 1.5, wideBlur: 4,
                    crispOpacity: 0.12, wideOpacity: 0.2)
    }

    private func hint(_ text: String) -> some View {
        layeredText(text, size: 14, weight: .medium, textOpacity: 0.5,
                    hPad: 16, vPad: 8, minScale: 0.8, crispBlur: 1.5, wideBlur: 4)
    }
}

// MARK: - 逐字卡拉OK（扫亮 + 波浪上浮 + 瀑布入场 + 整行辉光）

/// 一行逐字歌词。四层同构渲染：宽黑影 → 紧黑影 → 白色辉光 → 渐变正文，
/// 每层都是整行副本（同字号、同上浮位移），阴影辉光全部画成内容。
private struct KaraokeLine: View {
    let words: [LyricWord]
    let lineBegin: Double
    let position: Double

    private static let baseSize: CGFloat = 32
    private static var sizeCache: [String: CGFloat] = [:]

    private enum RowStyle {
        case wideShadow   // 氛围软影（整行常驻）
        case crispShadow  // 描边影（只在唱到后浮现）
        case glow         // 唱到的字的辉光
        case mainBlur     // 未唱：模糊的白字（失焦态）
        case mainSharp    // 唱到/唱过：清晰字（带扫亮）
    }

    var body: some View {
        let fontSize = Self.fittedFontSize(
            for: words.map(\.text).joined(),
            maxWidth: max(60, PanelController.shared.panelWidth - 64)
        )
        return ZStack {
                row(.wideShadow, fontSize: fontSize)
                    .padding(.horizontal, 26).padding(.vertical, 22)
                    .blur(radius: 9)
                row(.crispShadow, fontSize: fontSize)
                    .padding(.horizontal, 26).padding(.vertical, 22)
                    .offset(y: 1)
                    .blur(radius: 2.5)
                row(.glow, fontSize: fontSize)
                    .padding(.horizontal, 26).padding(.vertical, 22)
                    .blur(radius: 8)
                row(.mainBlur, fontSize: fontSize)
                    .padding(.horizontal, 26).padding(.vertical, 22)
                    .blur(radius: 2)
                row(.mainSharp, fontSize: fontSize)
                    .padding(.horizontal, 26).padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 94)
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
            Text(word.text).font(font).foregroundStyle(.white)
                .opacity(0.65 * active)
        case .mainBlur:
            Text(word.text).font(font).foregroundStyle(.white.opacity(0.5))
                .opacity(1 - focus)
        case .mainSharp:
            Text(word.text).font(font).foregroundStyle(.white)
                .opacity(focus)
        }
    }

    /// 对焦程度：快唱到前 0.45 秒开始聚拢，聚拢完成即全亮——
    /// 雾直接凝成亮字，不存在「清晰但半暗」的中间态
    private func focus(_ word: LyricWord) -> Double {
        smoothstep((position - word.begin + 0.45) / 0.45)
    }

    /// 按整行文字宽度算出不越界的字号（结果缓存，每行只算一次）
    private static func fittedFontSize(for text: String, maxWidth: CGFloat) -> CGFloat {
        let key = "\(Int(maxWidth))|\(text)"
        if let cached = sizeCache[key] { return cached }
        let descriptor = NSFont.systemFont(ofSize: baseSize, weight: .bold)
            .fontDescriptor.withDesign(.rounded)
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: baseSize) }
            ?? NSFont.systemFont(ofSize: baseSize, weight: .bold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let size = width > maxWidth ? max(16, baseSize * maxWidth / width) : baseSize
        if sizeCache.count > 500 { sizeCache.removeAll() }
        sizeCache[key] = size
        return size
    }

    /// 瀑布入场：换行后每个字依次延迟 40ms，用 0.35s 从下方浮起淡入
    private func entrance(index: Int) -> Double {
        smoothstep((position - lineBegin + 0.12 - Double(index) * 0.04) / 0.35)
    }

    /// 词内演唱进度 0..1（驱动从左到右的扫亮）
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

    /// 换行 = 向上滚动一格：新句从预告句的位置（下方 67px）半亮升入主位，
    /// 旧句同步向上淡出——和 Apple Music 内部歌词的滚动一致
    static let lyricMain = AnyTransition.asymmetric(
        insertion: .modifier(
            active: LyricTransitionModifier(opacity: 0, y: 67, blur: 0, scale: 1),
            identity: LyricTransitionModifier(opacity: 1, y: 0, blur: 0, scale: 1)
        ),
        removal: .modifier(
            active: LyricTransitionModifier(opacity: 0, y: -34, blur: 0, scale: 1),
            identity: LyricTransitionModifier(opacity: 1, y: 0, blur: 0, scale: 1)
        )
    )

    /// 逐字句：同样滚动一格升入，字级瀑布动画在升入过程中同步展开
    static let karaokeSwap = AnyTransition.asymmetric(
        insertion: .modifier(
            active: LyricTransitionModifier(opacity: 0, y: 67, blur: 0, scale: 1),
            identity: LyricTransitionModifier(opacity: 1, y: 0, blur: 0, scale: 1)
        ),
        removal: .modifier(
            active: LyricTransitionModifier(opacity: 0, y: -34, blur: 0, scale: 1),
            identity: LyricTransitionModifier(opacity: 1, y: 0, blur: 0, scale: 1)
        )
    )

    /// 预告句：出现由时钟中点淡入驱动；换行时快速淡出，把位置交给升入的主句
    static let lyricNext = AnyTransition.opacity
}
