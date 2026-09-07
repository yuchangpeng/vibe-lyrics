import SwiftUI

/// 完整歌词窗：全篇滚动、当前句高亮并自动居中、点任意句跳转
struct FullLyricsView: View {
    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var engine = LyricsEngine.shared

    var body: some View {
        Group {
            if case .ready(let lyrics) = engine.status {
                TimelineView(.periodic(from: .now, by: 0.4)) { context in
                    let position = player.currentPosition(at: context.date)
                        + UserDefaults.standard.double(forKey: "lyricsOffset")
                    let current = lyrics.currentIndex(at: position)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(lyrics.lines.indices, id: \.self) { i in
                                    lineRow(lyrics.lines[i], isCurrent: i == current, isPast: i < (current ?? -1))
                                        .id(i)
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 32)
                        }
                        .onChange(of: current) { _, new in
                            if let new {
                                withAnimation(.easeInOut(duration: 0.45)) {
                                    proxy.scrollTo(new, anchor: .center)
                                }
                            }
                        }
                        .onAppear {
                            if let current { proxy.scrollTo(current, anchor: .center) }
                        }
                    }
                }
            } else {
                Text(placeholder)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 500, idealHeight: 660)
        .background(.ultraThinMaterial)
        .navigationTitle(player.track.map { "\($0.name) — \($0.artist)" } ?? "完整歌词")
    }

    @ViewBuilder
    private func lineRow(_ line: LyricLine, isCurrent: Bool, isPast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(line.text)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(isPast ? 0.45 : 0.75)))
                .scaleEffect(isCurrent ? 1.02 : 1.0, anchor: .leading)
                .animation(.easeOut(duration: 0.3), value: isCurrent)
            if let translation = line.translation {
                Text(translation)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(isCurrent ? 0.9 : 0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            PlayerEngine.shared.seek(to: max(0, line.begin - 0.1))
        }
    }

    private var placeholder: String {
        switch engine.status {
        case .needsLogin: return "连接 Apple Music 账号后显示歌词"
        case .unavailable: return "这首歌没有可用歌词"
        case .loading: return "正在取歌词…"
        default: return "播放音乐后显示完整歌词"
        }
    }
}
