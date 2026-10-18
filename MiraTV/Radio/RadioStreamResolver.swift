import Foundation

/// 局 → 実際に再生する URL とエンジンの対応表。
/// iPhone 標準 (AVPlayer) で鳴るのは radiko / NHK / ListenRadio / manual の 219 局。
/// fmplapla (Ogg) と JCBA (WebSocket + Ogg/Opus) は FFmpeg エンジン側の対応待ち。
enum RadioEngine {
    /// AVPlayer に URL を渡すだけ（HLS / Icecast / audio/mp4）
    case avPlayer(URL)
    /// Ogg/Opus。TV 用 TSPipeline と同じ libavformat で開ける見込み（Step R2）
    case ffmpeg(URL)
    /// 現状は再生手段なし
    case unsupported(String)
}

struct RadioStreamResolver {
    let client: RadioWebClient

    /// 一覧で「再生可」フィルタに使う。ネットワーク不要の静的判定
    static func isNativelyPlayable(_ s: RadioStation) -> Bool {
        switch s.source {
        case .radiko, .nhk, .listenradio: true
        case .manual: s.streamUrl != nil
        case .fmplapla, .jcba, .unknown: false
        }
    }

    func resolveLive(_ s: RadioStation) async throws -> RadioEngine {
        switch s.source {
        case .radiko:
            // サーバーが radiko 認証・エリア判定を代行し、セグメント URL も書き換えてくれる
            return .avPlayer(client.url("live/radiko/\(s.id).m3u8"))
        case .nhk:
            // 302 で NHK の CDN master.m3u8 へ。AVPlayer はリダイレクトを追う
            guard let area = s.area, let band = s.band else {
                throw RadioWebError.unsupported("NHK の area/band が取得できません")
            }
            return .avPlayer(client.url("live/nhk/\(area)/\(band)"))
        case .listenradio:
            // Referer/Origin 注入のための再帰プロキシ。ダミー映像トラックがあるが音声のみで扱う
            // station.id は "lr:30011" だがパスは "30011"（"lr:" 付きだと 404 を実測）。
            // カタログの streamUrl（"/live/listenradio/30011/playlist.m3u8"）をそのまま使う
            guard let raw = s.streamUrl, let u = client.resolve(raw) else {
                throw RadioWebError.unsupported("ListenRadio の配信パスがありません")
            }
            return .avPlayer(u)
        case .manual:
            guard let raw = s.streamUrl, let u = URL(string: raw) else {
                throw RadioWebError.unsupported("配信 URL がありません")
            }
            return .avPlayer(u)
        case .fmplapla:
            return .ffmpeg(try await client.fmplaplaResolve(station: s.fmplaplaStation ?? s.id))
        case .jcba:
            return .unsupported("JCBA は WebSocket 配信のため未対応です")
        case .unknown:
            return .unsupported("未知の配信元です")
        }
    }

    /// アーカイブ: nzb → play トークン → /archive/stream/{token}（audio/mp4, Range 対応）
    func resolveArchive(nzb: String) async throws -> URL {
        let ticket = try await client.archivePlay(nzb: nzb)
        guard let u = client.resolve(ticket.url) else { throw URLError(.badURL) }
        return u
    }
}
