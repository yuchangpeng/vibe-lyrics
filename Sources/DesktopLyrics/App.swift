import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 一键隐藏/显示桌面歌词（默认 ⌥⌘L，之后可在设置里改）
    static let toggleLyrics = Self("toggleLyrics", default: .init(.l, modifiers: [.option, .command]))
}

@main
struct DesktopLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var panelController = PanelController.shared
    @ObservedObject private var engine = PlayerEngine.shared
    @ObservedObject private var auth = AppleMusicAuth.shared
    @AppStorage("lyricsOffset") private var lyricsOffset: Double = 0.12

    var body: some Scene {
        MenuBarExtra("Vibe Lyrics", systemImage: "music.note.list") {
            if let track = engine.track {
                Text("\(track.name) — \(track.artist)")
            } else {
                Text("Music 未在播放")
            }
            Divider()
            if auth.hasUserToken {
                Text("Apple Music 账号：已连接")
            } else {
                Button("连接 Apple Music 账号…") {
                    AppleMusicAuth.shared.showLogin()
                }
            }
            Button("重新获取本曲歌词") {
                LyricsEngine.shared.refetchCurrent()
            }
            Divider()
            Button(panelController.isVisible ? "隐藏歌词（⌥⌘L）" : "显示歌词（⌥⌘L）") {
                panelController.toggleVisible()
            }
            Toggle("鼠标穿透（锁定歌词）", isOn: $panelController.clickThrough)
            Menu("歌词时间微调（当前\(String(format: "%+.2f", lyricsOffset)) 秒）") {
                Button("提前 0.1 秒") { lyricsOffset = (lyricsOffset + 0.1).rounded(toPlaces: 2) }
                Button("延后 0.1 秒") { lyricsOffset = (lyricsOffset - 0.1).rounded(toPlaces: 2) }
                Button("恢复默认（+0.12）") { lyricsOffset = 0.12 }
            }
            Divider()
            Button("退出桌面歌词") {
                NSApp.terminate(nil)
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PanelController.shared.setUp()
        PlayerEngine.shared.start()
        LyricsEngine.shared.start()
        AppleMusicAuth.shared.checkUserTokenAtLaunch()
        KeyboardShortcuts.onKeyDown(for: .toggleLyrics) {
            PanelController.shared.toggleVisible()
        }
        DebugLog.log("[App] 桌面歌词已启动")
    }
}
