import Foundation
import Libavutil

// FFmpeg の関数マクロは Swift に取り込まれないので自前で定義する
/// AVERROR(EAGAIN)
let kAVErrorEAGAIN: Int32 = -EAGAIN
/// AVERROR_EOF = FFERRTAG('E','O','F',' ')
let kAVErrorEOF: Int32 = -0x2046_4F45
/// AV_NOPTS_VALUE
let kAVNoPTS: Int64 = Int64.min

func avErrorString(_ code: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    av_strerror(code, &buf, buf.count)
    return String(cString: buf)
}

extension AVRational {
    var double: Double { den == 0 ? 0 : Double(num) / Double(den) }
}

/// エラー文に載る URL の apikey=... は伏せる（画面・ログ・スクリーンショットに鍵が残らないように）
func redactSecrets(_ s: String) -> String {
    s.replacingOccurrences(of: "apikey=[^&\\s]+", with: "apikey=***", options: .regularExpression)
}

/// 通信エラーの原因が分かるように、種類・コード・失敗した URL・下位エラーまで文字列にする
func describeError(_ error: Error) -> String {
    let ns = error as NSError
    var s = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    if let u = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { s += "\n\(u)" }
    if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        s += "\n原因: \(under.domain) \(under.code) \(under.localizedDescription)"
    }
    // ATS(-1022)のときは、実機で実際に効いている設定を見せる（Info.plist が再署名で変わっていないか確認用）
    if ns.code == -1022 {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity")
        s += "\nATS(実行時): " + (ats.map { "\($0)" } ?? "設定なし")
    }
    return redactSecrets(s)
}

struct PipelineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    init(_ what: String, _ code: Int32) { self.message = "\(what): \(avErrorString(code))" }
    var errorDescription: String? { message }
}
