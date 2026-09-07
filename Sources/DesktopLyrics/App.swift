import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 一键隐藏/显示桌面歌词（默认 ⌥⌘L）
    static let toggleLyrics = Self("toggleLyrics", default: .init(.l, modifiers: [.option, .command]))
    /// 完全穿透（锁定歌词）开关（默认 ⌥⌘K）
    static let toggleClickThrough = Self("toggleClickThrough", default: .init(.k, modifiers: [.option, .command]))
}

@main
struct DesktopLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var panelController = PanelController.shared
    @ObservedObject private var engine = PlayerEngine.shared
    @ObservedObject private var auth = AppleMusicAuth.shared

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
            Toggle("完全穿透（⌥⌘K）", isOn: $panelController.clickThrough)
            SettingsLink {
                Text("设置…")
            }
            Divider()
            Button("退出 Vibe Lyrics") {
                NSApp.terminate(nil)
            }
        }
        Settings {
            SettingsView()
        }
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
        KeyboardShortcuts.onKeyDown(for: .toggleClickThrough) {
            PanelController.shared.clickThrough.toggle()
            DebugLog.log("[App] 快捷键切换完全穿透：\(PanelController.shared.clickThrough ? "开" : "关")")
        }
        DebugLog.log("[App] Vibe Lyrics 已启动")
    }
}
