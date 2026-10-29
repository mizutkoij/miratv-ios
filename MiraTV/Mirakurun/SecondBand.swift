import Foundation

/// 2 台目の Mirakurun / EPGStation は、放送波の枠（GR/BS/CS）に配信・海外の局を割り当てているだけなので、局名で種類を分ける。
/// 例: 地上波枠 = ABEMA、BS 枠 = MLB・各種配信、CS 枠 = 韓国の放送・DAZN
enum SecondBand {
    static let all = ["ABEMA", "MLB", "配信", "DAZN", "韓国", "他"]

    static func of(name n: String, type: String?) -> String {
        if n.hasPrefix("ABEMA") || type == "GR" { return "ABEMA" }
        if n.hasPrefix("MLB") { return "MLB" }
        if n.hasPrefix("DAZN") { return "DAZN" }
        if n.hasPrefix("QAM/") || n.hasPrefix("{") { return "他" }
        if type == "CS" { return "韓国" }
        return "配信"   // BS 枠: FOD / U-NEXT / Hulu / J-Sports / EasySports / 虎テレ / GIANTS TV / NHK World など
    }

    /// 2 台目のサービス ID（networkId 40000 以降 = 4,000,000,000 以上）か
    static func isSecond(channelId: Int) -> Bool { channelId >= 4_000_000_000 }
}
