import Foundation
import AppKit
import WebKit

enum AMError: Error {
    case needsLogin      // 缺少/失效 media-user-token，需要登录
    case tokenNotFound   // 网页里没抓到 developer token
    case http(Int)
    case badResponse
}

/// Apple Music 凭证管理：
/// - developer token（「渠道牌」）：从 music.apple.com 公开网页代码里抓，带缓存
/// - media-user-token（「会员卡」）：用户在内嵌登录窗口登录后，存在 WKWebView 的 cookie 里，自动持久化
final class AppleMusicAuth: NSObject, ObservableObject {
    static let shared = AppleMusicAuth()

    @Published var hasUserToken = false

    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// 登录成功后的回调（用来触发重新取词）
    var onLogin: (() -> Void)?

    private var loginWindow: NSWindow?
    private var loginWebView: WKWebView?
    private var cookiePollTimer: Timer?

    private override init() { super.init() }

    func checkUserTokenAtLaunch() {
        Task { @MainActor in
            let token = await self.mediaUserToken()
            self.hasUserToken = token != nil
            DebugLog.log("[鉴权] 启动检查：media-user-token \(token != nil ? "已有" : "没有")")
            if token == nil {
                self.showLogin()
            }
        }
    }

    // MARK: - media-user-token（登录时存入 UserDefaults，cookie 只作新鲜来源）

    private static let userTokenKey = "amUserToken"

    func mediaUserToken() async -> String? {
        if let fresh = await cookieUserToken() {
            // cookie 还在就顺手刷新备份
            UserDefaults.standard.set(fresh, forKey: Self.userTokenKey)
            return fresh
        }
        return UserDefaults.standard.string(forKey: Self.userTokenKey)
    }

    /// token 失效（服务器返回 401/403）时清掉备份，走重新登录
    func clearStoredUserToken() {
        UserDefaults.standard.removeObject(forKey: Self.userTokenKey)
    }

    private func cookieUserToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    let token = cookies.first { $0.name == "media-user-token" }?.value
                    continuation.resume(returning: token)
                }
            }
        }
    }

    // MARK: - developer token

    func developerToken(forceRefresh: Bool = false) async throws -> String {
        let defaults = UserDefaults.standard
        if !forceRefresh,
           let cached = defaults.string(forKey: "amDevToken"),
           defaults.double(forKey: "amDevTokenExp") > Date().timeIntervalSince1970 + 86400 {
            return cached
        }
        DebugLog.log("[鉴权] 抓取网页版 developer token…")
        let html = try await fetchText("https://music.apple.com/")
        let jsPaths = Self.matches("/assets/index[^\"']*?\\.js", in: html)
        var seen = Set<String>()
        for path in jsPaths where seen.insert(path).inserted {
            if seen.count > 6 { break }
            guard let js = try? await fetchText("https://music.apple.com" + path) else { continue }
            if let token = Self.matches("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", in: js).first {
                let exp = Self.jwtExpiry(token) ?? (Date().timeIntervalSince1970 + 60 * 86400)
                defaults.set(token, forKey: "amDevToken")
                defaults.set(exp, forKey: "amDevTokenExp")
                DebugLog.log("[鉴权] developer token 已更新，有效期至 \(Date(timeIntervalSince1970: exp))")
                return token
            }
        }
        throw AMError.tokenNotFound
    }

    private func fetchText(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw AMError.badResponse }
        var request = URLRequest(url: url)
        request.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AMError.badResponse
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    static func jwtExpiry(_ jwt: String) -> Double? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["exp"] as? Double
    }

    // MARK: - 登录窗口

    @MainActor
    func showLogin() {
        if loginWindow == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 660), configuration: config)
            webView.customUserAgent = Self.safariUA
            webView.load(URLRequest(url: URL(string: "https://music.apple.com/")!))

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "连接 Apple Music — 请登录你的 Apple 账户"
            window.contentView = webView
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            loginWindow = window
            loginWebView = webView
        }
        loginWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startCookiePolling()
        DebugLog.log("[鉴权] 已打开登录窗口")
    }

    private func startCookiePolling() {
        cookiePollTimer?.invalidate()
        cookiePollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if let token = await self.cookieUserToken() {
                    UserDefaults.standard.set(token, forKey: Self.userTokenKey)
                    DebugLog.log("[鉴权] 登录成功，media-user-token 已保存")
                    self.hasUserToken = true
                    self.stopCookiePolling()
                    self.loginWindow?.close()
                    self.onLogin?()
                }
            }
        }
    }

    private func stopCookiePolling() {
        cookiePollTimer?.invalidate()
        cookiePollTimer = nil
    }
}

extension AppleMusicAuth: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopCookiePolling()
    }
}
