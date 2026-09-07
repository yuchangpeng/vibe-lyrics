import AppKit

/// 统一的文字宽度测量（bold rounded 字体，带缓存）
enum TextMeasure {
    private static var cache: [String: CGFloat] = [:]

    static func width(of text: String, size: CGFloat) -> CGFloat {
        let key = "\(Int(size))|\(text)"
        if let cached = cache[key] { return cached }
        let descriptor = NSFont.systemFont(ofSize: size, weight: .bold)
            .fontDescriptor.withDesign(.rounded)
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        if cache.count > 600 { cache.removeAll() }
        cache[key] = width
        return width
    }
}
