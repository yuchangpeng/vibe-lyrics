import Foundation

/// amp-api.music.apple.com 请求封装（Apple Music 网页版同款接口）
final class AppleMusicAPI {
    static let shared = AppleMusicAPI()
    private init() {}

    private let base = "https://amp-api.music.apple.com"

    private func authedRequest(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let userToken = await AppleMusicAuth.shared.mediaUserToken() else {
            throw AMError.needsLogin
        }
        var devToken = try await AppleMusicAuth.shared.developerToken()
        var attempt = 0
        while true {
            attempt += 1
            guard var comps = URLComponents(string: base + path) else { throw AMError.badResponse }
            if !query.isEmpty { comps.queryItems = query }
            guard let url = comps.url else { throw AMError.badResponse }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(devToken)", forHTTPHeaderField: "Authorization")
            request.setValue(userToken, forHTTPHeaderField: "Media-User-Token")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            request.setValue(AppleMusicAuth.safariUA, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                return data
            case 401 where attempt == 1:
                DebugLog.log("[API] 401，developer token 可能过期，重抓一次")
                devToken = try await AppleMusicAuth.shared.developerToken(forceRefresh: true)
            case 401, 403:
                DebugLog.log("[API] HTTP \(code)：需要重新登录 Apple Music")
                AppleMusicAuth.shared.clearStoredUserToken()
                await MainActor.run { AppleMusicAuth.shared.hasUserToken = false }
                throw AMError.needsLogin
            default:
                throw AMError.http(code)
            }
        }
    }

    /// 用户账号所属地区（如 cn / us），带缓存
    func storefront() async throws -> String {
        if let cached = UserDefaults.standard.string(forKey: "amStorefront") { return cached }
        let data = try await authedRequest(path: "/v1/me/storefront")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let id = arr.first?["id"] as? String else {
            throw AMError.badResponse
        }
        UserDefaults.standard.set(id, forKey: "amStorefront")
        DebugLog.log("[API] storefront = \(id)")
        return id
    }

    /// 取歌词 TTML：优先逐字（syllable-lyrics），回退逐行（lyrics）；无词返回 nil
    func lyricsTTML(songID: String) async throws -> String? {
        let sf = try await storefront()
        for endpoint in ["syllable-lyrics", "lyrics"] {
            do {
                let data = try await authedRequest(path: "/v1/catalog/\(sf)/songs/\(songID)/\(endpoint)")
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = obj["data"] as? [[String: Any]],
                   let attrs = arr.first?["attributes"] as? [String: Any],
                   let ttml = attrs["ttml"] as? String, !ttml.isEmpty {
                    DebugLog.log("[API] 取到 \(endpoint)（\(ttml.count) 字符）")
                    return ttml
                }
            } catch AMError.http(let code) where code == 404 {
                continue
            }
        }
        return nil
    }

    /// 曲目封面 URL（600×600，分享卡用）
    func artworkURL(songID: String) async throws -> URL? {
        let sf = try await storefront()
        let data = try await authedRequest(path: "/v1/catalog/\(sf)/songs/\(songID)")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let attrs = arr.first?["attributes"] as? [String: Any],
              let artwork = attrs["artwork"] as? [String: Any],
              let template = artwork["url"] as? String else { return nil }
        let urlString = template
            .replacingOccurrences(of: "{w}", with: "600")
            .replacingOccurrences(of: "{h}", with: "600")
            .replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: urlString)
    }

    /// 按元数据搜索曲目目录 ID（拿不到 Store URL 时的兜底）
    func searchSongID(name: String, artist: String, album: String, duration: Double) async throws -> String? {
        let sf = try await storefront()
        let data = try await authedRequest(
            path: "/v1/catalog/\(sf)/search",
            query: [
                URLQueryItem(name: "term", value: "\(name) \(artist)"),
                URLQueryItem(name: "types", value: "songs"),
                URLQueryItem(name: "limit", value: "10"),
            ]
        )
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let items = songs["data"] as? [[String: Any]] else {
            return nil
        }

        let wantName = name.lowercased()
        let wantArtist = artist.lowercased()
        let wantAlbum = album.lowercased()
        var best: (id: String, score: Double)?
        for item in items {
            guard let id = item["id"] as? String,
                  let attrs = item["attributes"] as? [String: Any] else { continue }
            let n = (attrs["name"] as? String ?? "").lowercased()
            let a = (attrs["artistName"] as? String ?? "").lowercased()
            let al = (attrs["albumName"] as? String ?? "").lowercased()
            let dms = (attrs["durationInMillis"] as? Double) ?? -1

            var score = 0.0
            if duration > 0 && dms > 0 {
                let diff = abs(dms / 1000 - duration)
                if diff > 4 { continue } // 时长差 4 秒以上基本不是同一首
                score += max(0, 4 - diff)
            }
            if n == wantName { score += 4 } else if n.contains(wantName) || wantName.contains(n) { score += 2 }
            if a == wantArtist { score += 3 } else if a.contains(wantArtist) || wantArtist.contains(a) { score += 1.5 }
            if !wantAlbum.isEmpty && al == wantAlbum { score += 1 }
            if best == nil || score > best!.score { best = (id, score) }
        }
        if let best, best.score >= 3 {
            DebugLog.log("[API] 搜索匹配到曲目 id=\(best.id)（得分 \(String(format: "%.1f", best.score))）")
            return best.id
        }
        DebugLog.log("[API] 搜索没有可靠匹配：\(name) \(artist)")
        return nil
    }
}
