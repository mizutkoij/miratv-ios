import Foundation

/// streamd の追っかけ用バッファの状態（GET /timeshift/<局>/start・info）
struct TimeshiftInfo: Decodable, Equatable {
    /// バッファの番号。streamd が止めて作り直すと変わる（変わったら前の位置はもう無い）
    let id: Int64?
    /// 貯めた総バイト数
    let bytes: Int64
    /// バッファを始めてからの秒（＝ライブの端）
    let seconds: Double
    /// 残っている最初の位置（秒）。古い分は TIMESHIFT_MINUTES を過ぎると消える
    let availableFrom: Double
    let stopped: Bool?

    enum CodingKeys: String, CodingKey {
        case id, bytes, seconds, stopped
        case availableFrom = "available_from"
    }
}

enum TimeshiftClient {
    /// 貯め始める（すでに貯めていればそのまま）。5 秒おきに呼ぶと「見ている」合図にもなり、止まらない
    static func start(_ service: MirakurunService) async -> TimeshiftInfo? {
        guard let url = Servers.timeshiftURL(service, "start") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, res) = try? await Net.data(for: req, retries: 0),
              (res as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(TimeshiftInfo.self, from: data)
    }

    /// 別の局に切り替えた・閉じたとき（待たずに投げるだけ）。ほかの端末が同じ局を見ていれば streamd は止めない
    static func stop(_ service: MirakurunService) {
        guard let url = Servers.timeshiftURL(service, "stop") else { return }
        Task.detached { _ = try? await URLSession.shared.data(from: url) }
    }
}
