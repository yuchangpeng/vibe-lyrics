import SwiftUI
import AppKit

/// 分享卡：把正在唱的这句渲染成一张卡片，复制到剪贴板并存到「下载」
enum ShareCard {
    @MainActor
    static func generate() {
        let player = PlayerEngine.shared
        guard let track = player.track else {
            DebugLog.log("[分享卡] 无播放曲目，跳过")
            return
        }
        var line = ""
        if case .ready(let lyrics) = LyricsEngine.shared.status {
            let position = player.currentPosition() + UserDefaults.standard.double(forKey: "lyricsOffset")
            if let index = lyrics.currentIndex(at: position) {
                line = lyrics.lines[index].text
            }
        }
        if line.isEmpty { line = track.name }

        let view = ShareCardView(line: line, title: track.name, artist: track.artist)
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
}

/// 卡片设计：海报同款的 Apple 简约风（1200×630）
struct ShareCardView: View {
    let line: String
    let title: String
    let artist: String

    var body: some View {
        ZStack {
            Color(red: 0.961, green: 0.961, blue: 0.969) // #F5F5F7
            VStack(spacing: 0) {
                Spacer()
                Text(line)
                    .font(.system(size: 62, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.114, green: 0.114, blue: 0.122)) // #1D1D1F
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 90)
                Text("\(title) — \(artist)")
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.525, green: 0.525, blue: 0.545)) // #86868B
                    .lineLimit(1)
                    .padding(.top, 36)
                Spacer()
                Text("♪ Vibe Lyrics")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.63, green: 0.63, blue: 0.65))
                    .padding(.bottom, 44)
            }
        }
        .frame(width: 1200, height: 630)
    }
}
