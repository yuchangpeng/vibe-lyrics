import SwiftUI
import AppKit

// SHARECARD_PREVIEW 编译开关：渲染测试台只编译视图部分
/// 分享卡「正在唱的那一刻」：
/// 封面重模糊做背景（玻璃感/专辑色）+ 微倾封面卡带倒影 + 冻结的卡拉OK瞬间。
/// 生成后复制到剪贴板并存到「下载」。
#if !SHARECARD_PREVIEW
enum ShareCard {
    static func generate() {
        Task { @MainActor in
            await generateCard()
        }
    }

    @MainActor
    private static func generateCard() async {
        let player = PlayerEngine.shared
        guard let track = player.track else {
            DebugLog.log("[分享卡] 无播放曲目，跳过")
            return
        }

        // 按下分享那一刻的真实演唱进度
        var sung = track.name
        var fog = ""
        var next = ""
        if case .ready(let lyrics) = LyricsEngine.shared.status {
            let position = player.currentPosition() + UserDefaults.standard.double(forKey: "lyricsOffset")
            if let index = lyrics.currentIndex(at: position) {
                (sung, fog) = split(lyrics.lines[index], at: position)
                if index + 1 < lyrics.lines.count {
                    next = lyrics.lines[index + 1].text
                }
            } else if let first = lyrics.lines.first {
                sung = ""
                fog = first.text
            }
        }

        // 封面：Apple 目录原图
        var cover: NSImage?
        if let songID = LyricsEngine.shared.cachedSongID(for: track),
           let url = try? await AppleMusicAPI.shared.artworkURL(songID: songID),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            cover = NSImage(data: data)
        }
        if cover == nil { DebugLog.log("[分享卡] 未取到封面，使用素底") }

        let view = ShareCardView(
            sung: sung, fog: fog, next: next,
            title: track.name, artist: track.artist, cover: cover
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            DebugLog.log("[分享卡] 渲染失败")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/VibeLyrics-\(formatter.string(from: Date())).png")
        try? png.write(to: url)
        DebugLog.log("[分享卡] 已复制到剪贴板并保存：\(url.lastPathComponent)")
    }

    /// 把当前句按演唱进度切成「唱过（亮）/未唱（雾）」两段
    private static func split(_ line: LyricLine, at position: Double) -> (String, String) {
        if let words = line.words, !words.isEmpty {
            let sung = words.filter { $0.begin <= position }.map(\.text).joined()
            let fog = words.filter { $0.begin > position }.map(\.text).joined()
            return (sung, fog)
        }
        let text = line.text
        guard line.end > line.begin else { return (text, "") }
        let p = min(1, max(0, (position - line.begin) / (line.end - line.begin)))
        let cut = Int(Double(text.count) * p)
        let index = text.index(text.startIndex, offsetBy: cut)
        return (String(text[..<index]), String(text[index...]))
    }
}

#endif

/// v4 设计「正在唱的那一刻」，1200×560
struct ShareCardView: View {
    let sung: String
    let fog: String
    let next: String
    let title: String
    let artist: String
    let cover: NSImage?

    private let canvas = CGSize(width: 1200, height: 560)

    var body: some View {
        ZStack {
            background
            Color.clear.overlay(streak)
            Color.clear.overlay(ghostNote)
            HStack(spacing: 0) {
                leftColumn
                    .frame(width: 330)
                rightColumn
                    .padding(.leading, 66)
                Spacer(minLength: 0)
            }
            .padding(.leading, 78)
            .padding(.trailing, 60)
            .padding(.bottom, 26)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            Text("♪ Vibe Lyrics")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.trailing, 44)
                .padding(.bottom, 30)
        }
    }

    // MARK: 背景

    @ViewBuilder
    private var background: some View {
        if let cover {
            Image(nsImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(1.4)
                .blur(radius: 80)
                .saturation(1.5)
                .brightness(-0.03)
                .overlay(veil)
        } else {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.17, blue: 0.21), Color(red: 0.06, green: 0.06, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var veil: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.38), location: 0),
                .init(color: .black.opacity(0.12), location: 0.55),
                .init(color: .black.opacity(0.34), location: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 一道穿过玻璃的斜光
    private var streak: some View {
        Rectangle()
            .fill(LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.05),
                    .init(color: .white.opacity(0.09), location: 0.45),
                    .init(color: .white.opacity(0.13), location: 0.55),
                    .init(color: .clear, location: 0.95),
                ],
                startPoint: .leading, endPoint: .trailing
            ))
            .frame(width: 1560, height: 200)
            .rotationEffect(.degrees(-14))
            .offset(y: -66)
            .blur(radius: 26)
    }

    /// 巨大的极淡音符：纹理层
    private var ghostNote: some View {
        Text("♪")
            .font(.system(size: 560, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.045))
            .blur(radius: 16)
            .offset(x: 430, y: -140)
    }

    // MARK: 左列（悬浮封面卡 + 歌名歌手）

    private var leftColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                coverCard
                // 倒影：纯净副本（无阴影无描边），只画不占布局
                coverBase
                    .scaleEffect(x: 1, y: -1)
                    .mask(LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.30), location: 0),
                            .init(color: .clear, location: 0.30),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(height: 0, alignment: .top)
            }
            .rotationEffect(.degrees(-2.5))
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 34)
            Text(artist)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .padding(.top, 7)
        }
    }

    private var coverCard: some View {
        coverBase
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 40, y: 17)
            .shadow(color: .black.opacity(0.35), radius: 11, y: 3)
    }

    @ViewBuilder
    private var coverBase: some View {
        Group {
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.25, green: 0.26, blue: 0.3), Color(red: 0.12, green: 0.13, blue: 0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Text("♪")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
        .frame(width: 316, height: 316)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: 右列（冻结的卡拉OK瞬间）

    private var rightColumn: some View {
        let fullLine = sung + fog
        let mainSize = fitted(fullLine, base: 58, maxWidth: 660)
        let nextSize = fitted(next, base: 30, maxWidth: 660)
        return VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 0) {
                if !sung.isEmpty {
                    Text(sung)
                        .font(.system(size: mainSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.97))
                        .shadow(color: .white.opacity(0.28), radius: 13)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 1)
                }
                if !fog.isEmpty {
                    Text(fog)
                        .font(.system(size: mainSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .blur(radius: 2.2)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                }
            }
            .lineLimit(1)
            .fixedSize()
            if !next.isEmpty {
                Text(next)
                    .font(.system(size: nextSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .shadow(color: .black.opacity(0.4), radius: 7, y: 1)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// 一行放不下时按测量结果缩字号（两段文字必须同字号，不能用 minimumScaleFactor）
    private func fitted(_ text: String, base: CGFloat, maxWidth: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return base }
        let width = TextMeasure.width(of: text, size: base)
        return width > maxWidth ? max(20, base * maxWidth / width) : base
    }
}
