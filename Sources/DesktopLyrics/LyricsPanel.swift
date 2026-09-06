import AppKit
import SwiftUI
import QuartzCore

/// 无边框、不抢焦点、悬浮置顶的歌词窗
final class LyricsPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 悬浮窗控制器：创建、显示/隐藏、鼠标穿透
final class PanelController: ObservableObject {
    static let shared = PanelController()

    @Published var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: "panelVisible")
            apply()
        }
    }

    @Published var clickThrough: Bool {
        didSet {
            UserDefaults.standard.set(clickThrough, forKey: "clickThrough")
            panel?.ignoresMouseEvents = clickThrough
        }
    }

    private var panel: LyricsPanel?

    /// 悬浮窗宽度（固定值，供歌词排版计算字号用，避免运行时 GeometryReader 测量）
    private(set) var panelWidth: CGFloat = 920

    private init() {
        isVisible = UserDefaults.standard.object(forKey: "panelVisible") as? Bool ?? true
        clickThrough = UserDefaults.standard.bool(forKey: "clickThrough")
    }

    func setUp() {
        let size = NSSize(width: 920, height: 170)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 84)
        let panel = LyricsPanel(contentRect: NSRect(origin: origin, size: size))
        panel.setFrameAutosaveName("LyricsPanelFrame.v2")
        // 不裁剪超出边界的绘制，否则文字阴影/光晕会被窗口边缘切成方形
        let hosting = NSHostingView(rootView: OverlayView())
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        panel.contentView = hosting
        panel.ignoresMouseEvents = clickThrough
        panelWidth = panel.frame.width
        self.panel = panel
        apply()
    }

    func toggleVisible() {
        isVisible.toggle()
    }

    private func apply() {
        guard let panel else { return }
        if isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            })
        }
    }
}
