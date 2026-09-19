import Foundation
import AppKit
import CoreAudio
import Accelerate
import Combine
import SwiftUI

/// 真实音频频谱：用 Core Audio process tap 捕捉 Music 的输出声音，
/// FFT 分析成 56 段能量，驱动「音乐线条」。
/// 声音只在本机内存里实时分析，不录存、不上传。
final class AudioSpectrum: ObservableObject {
    static let shared = AudioSpectrum()
    static let bandCount = 56

    /// 引擎就绪且在跑（未授权/未开启时为 false，界面隐藏线条）
    @Published private(set) var available = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var failureLogged = false

    private let lock = NSLock()
    private var bands = [Float](repeating: 0, count: AudioSpectrum.bandCount)
    private var analyzeCount = 0

    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var ring = [Float]()
    private var sampleRate: Double = 48000

    private var bag = Set<AnyCancellable>()

    private init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    static var settingOn: Bool {
        UserDefaults.standard.object(forKey: "showSpectrum") as? Bool ?? true
    }

    /// App 启动时调用：跟随 Music 运行状态自动开合
    func startEngine() {
        PlayerEngine.shared.$musicRunning
            .removeDuplicates()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateDesiredState() }
            .store(in: &bag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateDesiredState()
        }
    }

    /// 设置开关变化时也调用
    func updateDesiredState() {
        let wanted = Self.settingOn && PlayerEngine.shared.musicRunning
        if wanted && !running { startCapture() }
        if !wanted && running { stopCapture() }
    }

    /// 当前 56 段能量（0..1），渲染每帧取
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return bands
    }

    // MARK: - Core Audio 捕捉

    private func startCapture() {
        guard !running else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music").first else { return }

        // PID → CoreAudio 进程对象
        var pid = app.processIdentifier
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &dataSize, &processObject
        )
        guard status == noErr, processObject != AudioObjectID(kAudioObjectUnknown) else {
            DebugLog.log("[频谱] 找不到 Music 的音频进程（\(status)）")
            return
        }

        // 建 tap（首次会触发「录制系统音频」授权弹窗）
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = UUID()
        description.name = "Vibe Lyrics Spectrum"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            if !failureLogged {
                failureLogged = true
                DebugLog.log("[频谱] 音频捕捉建立失败（\(status)），可能未授权「录制系统音频」")
            }
            return
        }
        tapID = tap

        // 读取 tap 输出格式（拿采样率）
        var fmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(tap, &fmtAddress, 0, nil, &fmtSize, &fmt) == noErr,
           fmt.mSampleRate > 0 {
            sampleRate = fmt.mSampleRate
        }

        // 只含 tap 的私有聚合设备
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Vibe Lyrics Spectrum",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[String: Any]](),
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else {
            DebugLog.log("[频谱] 聚合设备创建失败（\(status)）")
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            return
        }
        aggregateID = agg

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { [weak self] _, inInputData, _, _, _ in
            self?.consume(inInputData)
        }
        guard status == noErr, procID != nil else {
            DebugLog.log("[频谱] IOProc 创建失败（\(status)）")
            stopCapture(force: true)
            return
        }
        status = AudioDeviceStart(agg, procID)
        guard status == noErr else {
            DebugLog.log("[频谱] 设备启动失败（\(status)）")
            stopCapture(force: true)
            return
        }

        running = true
        failureLogged = false
        DispatchQueue.main.async { self.available = true }
        DebugLog.log("[频谱] 音频捕捉已启动（采样率 \(Int(sampleRate))）")
    }

    private func stopCapture(force: Bool = false) {
        guard running || force else { return }
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
        lock.lock()
        bands = [Float](repeating: 0, count: Self.bandCount)
        lock.unlock()
        DispatchQueue.main.async { self.available = false }
        DebugLog.log("[频谱] 音频捕捉已停止")
    }

    // MARK: - 分析（音频线程）

    private func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frames = total / channels
        guard frames > 0 else { return }
        let ptr = data.bindMemory(to: Float.self, capacity: total)

        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: ptr, count: frames)
            }
        } else {
            var i = 0
            for f in 0..<frames {
                mono[f] = ptr[i] // 取左声道足够可视化
                i += channels
            }
        }
        ring.append(contentsOf: mono)
        while ring.count >= fftSize {
            analyze(Array(ring.suffix(fftSize)))
            ring.removeFirst(min(ring.count, fftSize / 2))
        }
        if ring.count > fftSize * 4 {
            ring.removeFirst(ring.count - fftSize)
        }
    }

    private func analyze(_ samples: [Float]) {
        guard let fftSetup else { return }
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var mags = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }

        // 56 段对数分布（约 45Hz ~ 14kHz），dB 归一 + 快起慢落
        let minF = 45.0, maxF = 14000.0
        let binHz = sampleRate / Double(fftSize)
        var newBands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let f0 = minF * pow(maxF / minF, Double(b) / Double(Self.bandCount))
            let f1 = minF * pow(maxF / minF, Double(b + 1) / Double(Self.bandCount))
            let i0 = max(1, Int(f0 / binHz))
            let i1 = max(i0 + 1, min(fftSize / 2 - 1, Int(f1 / binHz)))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, mags[i]) }
            let db = 20 * log10(Double(peak) / Double(fftSize) + 1e-9)
            newBands[b] = Float(min(1, max(0, (db + 58) / 42)))
        }
        lock.lock()
        for b in 0..<Self.bandCount {
            let target = newBands[b]
            let current = bands[b]
            if target > current {
                bands[b] = current + (target - current) * 0.62 // 上冲柔化，不瞬跳
            } else {
                bands[b] = current * 0.90 + target * 0.10     // 回落更缓
            }
        }
        // 空间平滑：相邻条互相牵连，整排如液体涌动
        var smoothed = bands
        for b in 1..<(Self.bandCount - 1) {
            smoothed[b] = (bands[b - 1] + bands[b] * 2 + bands[b + 1]) / 4
        }
        bands = smoothed
        lock.unlock()
        analyzeCount += 1
        if analyzeCount % 250 == 1 {
            let peak = newBands.max() ?? 0
            DebugLog.log("[频谱] 心跳 peak=\(String(format: "%.2f", peak))")
        }
    }
}

// MARK: - 独立音乐线条悬浮窗（不依附歌词条，屏幕上/下居中，永远穿透）

@MainActor
final class SpectrumPanelController: ObservableObject {
    static let shared = SpectrumPanelController()

    /// 快捷键控制的显隐（与设置总开关、引擎就绪相与）
    @Published var visible: Bool {
        didSet {
            UserDefaults.standard.set(visible, forKey: "spectrumBarsVisible")
            apply()
        }
    }

    private var panel: NSPanel?
    private var bag = Set<AnyCancellable>()

    private init() {
        visible = UserDefaults.standard.object(forKey: "spectrumBarsVisible") as? Bool ?? true
    }

    func setUp() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // 纯展示，永远穿透
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SpectrumWindowView())
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        panel.contentView = hosting
        self.panel = panel
        reposition()
        apply()

        AudioSpectrum.shared.$available
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &bag)
    }

    func toggle() { visible.toggle() }

    /// 位置（屏幕底部/顶部，水平居中）；设置变化时调用
    func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let top = (UserDefaults.standard.string(forKey: "spectrumPosition") ?? "bottom") == "top"
        // 底部按整屏算固定 100pt：自动隐藏的程序坞弹出时也在线条下方
        let y = top ? vf.maxY - size.height - 8 : screen.frame.minY + 100
        panel.setFrame(
            NSRect(x: vf.midX - size.width / 2, y: y, width: size.width, height: size.height),
            display: false
        )
    }

    private func apply() {
        guard let panel else { return }
        if visible && AudioSpectrum.shared.available {
            reposition()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                if !(self.visible && AudioSpectrum.shared.available) {
                    self.panel?.orderOut(nil)
                }
            })
        }
    }
}

/// 独立线条窗的内容
struct SpectrumWindowView: View {
    @AppStorage("lyricTint") private var tintRaw = LyricTint.white.rawValue
    @ObservedObject private var spectrum = AudioSpectrum.shared

    private var tint: Color { (LyricTint(rawValue: tintRaw) ?? .white).color }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spectrum.available)) { context in
            SpectrumBars(tint: tint, tick: context.date)
                .frame(width: 520, height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 音乐线条视图（尺寸由调用方定，需在 TimelineView 内驱动重绘）

struct SpectrumBars: View {
    var tint: Color
    /// 每帧变化的时间戳：没有它 SwiftUI 会认为视图没变而跳过重绘
    var tick: Date

    var body: some View {
        Canvas { context, size in
            let levels = AudioSpectrum.shared.snapshot()
            let n = levels.count
            let barWidth: CGFloat = 4
            let gap = (size.width - CGFloat(n) * barWidth) / CGFloat(n - 1)
            for i in 0..<n {
                let a = CGFloat(levels[i])
                let h = max(3, a * size.height)
                let x = CGFloat(i) * (barWidth + gap)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(tint.opacity(0.30 + 0.55 * Double(a)))
                )
            }
        }
        .allowsHitTesting(false)
    }
}
