import SwiftUI
import ServiceManagement

/// 歌词颜色预设（阴影恒为黑，只染文字/雾/辉光）
enum LyricTint: String, CaseIterable {
    case white, gold, pink, blue, mint

    var label: String {
        switch self {
        case .white: "白"
        case .gold: "金"
        case .pink: "粉"
        case .blue: "蓝"
        case .mint: "薄荷"
        }
    }

    var color: Color {
        switch self {
        case .white: Color.white
        case .gold: Color(red: 1.0, green: 0.83, blue: 0.55)
        case .pink: Color(red: 1.0, green: 0.73, blue: 0.80)
        case .blue: Color(red: 0.62, green: 0.83, blue: 1.0)
        case .mint: Color(red: 0.66, green: 0.95, blue: 0.79)
        }
    }
}

struct SettingsView: View {
    @AppStorage("fontSize") private var fontSize = 32.0
    @AppStorage("lyricsOffset") private var lyricsOffset = 0.12
    @AppStorage("showPreview") private var showPreview = true
    @AppStorage("showTranslation") private var showTranslation = true
    @AppStorage("lyricTint") private var tintRaw = LyricTint.white.rawValue
    @ObservedObject private var panelController = PanelController.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("外观") {
                HStack {
                    Text("字号")
                    Slider(value: $fontSize, in: 24...44, step: 1)
                    Text("\(Int(fontSize))")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                Picker("歌词颜色", selection: $tintRaw) {
                    ForEach(LyricTint.allCases, id: \.rawValue) { tint in
                        Text(tint.label).tag(tint.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("显示下一句预告", isOn: $showPreview)
                Toggle("显示官方翻译（歌曲带翻译时）", isOn: $showTranslation)
            }
            Section("同步") {
                HStack {
                    Text("歌词提前")
                    Slider(value: $lyricsOffset, in: -1...1, step: 0.05)
                    Text(String(format: "%+.2fs", lyricsOffset))
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
            Section("行为") {
                Toggle("鼠标穿透（锁定歌词条）", isOn: $panelController.clickThrough)
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            DebugLog.log("[设置] 开机自启：\(enabled ? "开" : "关")")
                        } catch {
                            DebugLog.log("[设置] 开机自启设置失败：\(error.localizedDescription)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
