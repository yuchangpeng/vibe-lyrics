import Foundation

struct LyricWord: Equatable {
    var text: String
    var begin: Double
    var end: Double
}

struct LyricLine: Equatable {
    var begin: Double
    var end: Double
    var text: String
    /// 逐字时间轴（syllable 歌词才有），卡拉OK渲染用
    var words: [LyricWord]?
    /// TTML 行标识（itunes:key），用于对应官方翻译
    var key: String?
    /// 官方翻译（歌曲带翻译时）
    var translation: String?
}

struct Lyrics: Equatable {
    var lines: [LyricLine]
    var wordTimed: Bool
    /// 整首歌是否带官方翻译（决定翻译槽位是否保留）
    var hasTranslation: Bool

    /// 当前应显示的行：最后一个 begin <= t 的行；t 在第一句之前时返回 nil
    func currentIndex(at t: Double) -> Int? {
        var index: Int?
        for (i, line) in lines.enumerated() {
            if line.begin <= t { index = i } else { break }
        }
        return index
    }
}

enum TTMLParser {
    /// Apple TTML 歌词解析（兼容逐行 timing="Line" 和逐字 timing="Word"，含官方翻译）。
    /// 用 SAX（XMLParser）而不是 XMLDocument：后者会丢掉词与词之间的纯空格文本节点。
    static func parse(_ ttml: String) -> Lyrics? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let sax = SAXDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = sax
        parser.shouldProcessNamespaces = true
        guard parser.parse() || !sax.lines.isEmpty else { return nil }
        guard !sax.lines.isEmpty else { return nil }
        var lines = sax.lines
        if !sax.translations.isEmpty {
            for i in lines.indices {
                if let key = lines[i].key, let t = sax.translations[key] {
                    lines[i].translation = t
                }
            }
        }
        let wordTimed = sax.timing.lowercased() == "word"
            || lines.contains { $0.words?.isEmpty == false }
        let hasTranslation = lines.contains { $0.translation != nil }
        return Lyrics(lines: lines, wordTimed: wordTimed, hasTranslation: hasTranslation)
    }

    /// "15.055" / "1:15.055" / "1:02:03.004" → 秒
    static func parseTime(_ s: String?) -> Double? {
        guard var value = s, !value.isEmpty else { return nil }
        if value.hasSuffix("s") { value.removeLast() }
        var seconds = 0.0
        for part in value.split(separator: ":") {
            guard let v = Double(part) else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    private final class SAXDelegate: NSObject, XMLParserDelegate {
        var timing = "Line"
        var lines: [LyricLine] = []
        /// 行 key → 翻译文本（head 里的 iTunesMetadata/translations）
        var translations: [String: String] = [:]

        // 当前 <p>（一行）的累积状态
        private var inLine = false
        private var lineBegin: Double = 0
        private var lineEnd: Double = 0
        private var lineKey: String?
        private var lineText = ""
        private var words: [LyricWord] = []

        // 当前 <span>（一个词）的累积状态；背景和声（x-bg）整棵子树跳过
        private var spanStack: [(begin: Double?, end: Double?, isBackground: Bool)] = []
        private var wordText = ""
        private var backgroundDepth = 0

        // 翻译解析状态：只取第一个 <translation> 块（通常即用户语言）
        private var translationBlockCount = 0
        private var currentTranslationKey: String?
        private var translationBuffer = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "tt":
                if let t = attributes["itunes:timing"] { timing = t }
            case "translation":
                translationBlockCount += 1
            case "text" where translationBlockCount == 1 && !inLine:
                if let key = attributes["for"] {
                    currentTranslationKey = key
                    translationBuffer = ""
                }
            case "p":
                guard let begin = TTMLParser.parseTime(attributes["begin"]) else { return }
                inLine = true
                lineBegin = begin
                lineEnd = TTMLParser.parseTime(attributes["end"]) ?? begin
                lineKey = attributes["itunes:key"]
                lineText = ""
                words = []
                spanStack = []
                backgroundDepth = 0
            case "span" where inLine:
                let isBackground = backgroundDepth > 0
                    || (attributes["ttm:role"] ?? "").contains("x-bg")
                if isBackground { backgroundDepth += 1 }
                spanStack.append((
                    TTMLParser.parseTime(attributes["begin"]),
                    TTMLParser.parseTime(attributes["end"]),
                    isBackground
                ))
                if !isBackground { wordText = "" }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentTranslationKey != nil {
                translationBuffer += string
                return
            }
            guard inLine, backgroundDepth == 0 else { return }
            lineText += string
            if let top = spanStack.last, top.begin != nil {
                wordText += string
            } else if !words.isEmpty {
                // <p> 直接子文本（词与词之间的空格）挂到上一个词尾
                words[words.count - 1].text += string
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName {
            case "text":
                if let key = currentTranslationKey {
                    let t = translationBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { translations[key] = t }
                    currentTranslationKey = nil
                }
            case "span" where inLine && !spanStack.isEmpty:
                let top = spanStack.removeLast()
                if top.isBackground {
                    backgroundDepth -= 1
                } else if let begin = top.begin, let end = top.end, !wordText.isEmpty {
                    words.append(LyricWord(text: wordText, begin: begin, end: end))
                    wordText = ""
                }
            case "p" where inLine:
                inLine = false
                let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append(LyricLine(
                        begin: lineBegin, end: lineEnd,
                        text: trimmed,
                        words: words.isEmpty ? nil : words,
                        key: lineKey
                    ))
                }
            default:
                break
            }
        }
    }
}
