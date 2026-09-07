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

/// 悬浮窗控制器：创建、显示/隐藏、智能穿透
final class PanelController: ObservableObject {
    static let shared = PanelController()

    @Published var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: "panelVisible")
            apply()
        }
    }

    /// 完全穿透（锁定）：连歌词文字上也点不到；平时空白区域本来就自动穿透
    @Published var clickThrough: Bool {
        didSet {
            UserDefaults.standard.set(clickThrough, forKey: "clickThrough")
        }
    }

    private var panel: LyricsPanel?
    private var mouseTimer: Timer?

    /// 悬浮窗宽度（固定值，供歌词排版计算字号用，避免运行时 GeometryReader 测量）
    private(set) var panelWidth: CGFloat = 920

    /// 当前歌词内容的可交互区域信息（由 OverlayView 汇报）
    private var interactiveTextWidth: CGFloat = .infinity
    private var interactiveBandTop: CGFloat = 0
    private var interactiveBandHeight: CGFloat = 9999

    private init() {
        isVisible = UserDefaults.standard.object(forKey: "panelVisible") as? Bool ?? true
        clickThrough = UserDefaults.standard.bool(forKey: "clickThrough")
    }

    func setUp() {
        let size = NSSize(width: 920, height: 260)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 70)
        let panel = LyricsPanel(contentRect: NSRect(origin: origin, size: size))
        panel.setFrameAutosaveName("LyricsPanelFrame.v3")
        // 不裁剪超出边界的绘制，否则文字阴影/光晕会被窗口边缘切成方形
        let hosting = NSHostingView(rootView: OverlayView())
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        panel.contentView = hosting
        panelWidth = panel.frame.width
        self.panel = panel
        apply()

        // 智能穿透：20 次/秒检查鼠标是否悬在歌词文字附近
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateMouseThrough()
        }
        timer.tolerance = 0.02
        mouseTimer = timer
    }

    /// OverlayView 每次换行时汇报当前文字宽度和内容布局，用于计算可交互区域
    func updateContentMetrics(fontSize: CGFloat, showTranslation: Bool, textWidth: CGFloat) {
        let lineHeight = fontSize * 2.9
        let translationHeight = showTranslation ? fontSize * 0.95 : 0
        let nextHeight = fontSize * 1.25
        let contentHeight = lineHeight + translationHeight + nextHeight
        let panelHeight = panel?.frame.height ?? 260
        interactiveBandTop = (panelHeight - contentHeight) / 2
        interactiveBandHeight = lineHeight + translationHeight
        interactiveTextWidth = textWidth
    }

    private func updateMouseThrough() {
        guard let panel, isVisible else { return }
        if clickThrough {
            panel.ignoresMouseEvents = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let bandWidth = min(frame.width, interactiveTextWidth + 80)
        let band = NSRect(
            x: frame.midX - bandWidth / 2,
            y: frame.maxY - interactiveBandTop - interactiveBandHeight,
            width: bandWidth,
            height: interactiveBandHeight
        )
        panel.ignoresMouseEvents = !band.contains(mouse)
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
