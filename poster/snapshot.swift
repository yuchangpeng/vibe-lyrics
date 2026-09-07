// 用 WKWebView 把 HTML 渲染成指定像素尺寸的 PNG
// 用法: snapshot <html路径> <输出png> <宽> <高>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5,
      let width = Double(args[3]), let height = Double(args[4]) else {
    print("用法: snapshot <html> <png> <宽> <高>")
    exit(1)
}
let htmlURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: width, height: height),
    styleMask: [.borderless], backing: .buffered, defer: false
)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
webView.setValue(false, forKey: "drawsBackground") // 透明背景（图标等场景）
window.contentView = webView

final class SnapDelegate: NSObject, WKNavigationDelegate {
    let outURL: URL
    let width: Double
    let height: Double
    init(outURL: URL, width: Double, height: Double) {
        self.outURL = outURL
        self.width = width
        self.height = height
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等字体和布局稳定
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: self.width, height: self.height)
            config.snapshotWidth = NSNumber(value: self.width) // 输出像素宽 = 指定宽
            webView.takeSnapshot(with: config) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("截图失败: \(error?.localizedDescription ?? "未知")")
                    exit(1)
                }
                do {
                    try png.write(to: self.outURL)
                    print("完成 \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(self.outURL.path)")
                    exit(0)
                } catch {
                    print("写文件失败: \(error)")
                    exit(1)
                }
            }
        }
    }
}

let delegate = SnapDelegate(outURL: outURL, width: width, height: height)
webView.navigationDelegate = delegate
webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

// 超时保护
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("超时")
    exit(1)
}
app.run()
