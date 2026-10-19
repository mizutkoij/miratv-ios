import Foundation

/// 番組名から「シリーズ名」を取り出す（同じ番組の別の回をまとめるため）。
///
/// 例:
/// - `ガオトラ！タイガース中継2026 阪神vs北海道日本ハム(5．27)` → `ガオトラ!タイガース中継`
/// - `ドラマ名 #12「サブタイトル」` → `ドラマ名`
/// - `アニメ名 第3話 サブタイトル` → `アニメ名`
/// - `金曜ロードショー 映画のタイトル` → `金曜ロードショー`
///
/// 名前の付け方は局ごとにばらばらなので完全ではない。外れたときは「1 回だけの番組」として扱われるだけで、
/// 再生や検索には影響しない。裏のスレッドから呼ぶ（actor に属さない）
enum SeriesKey {
    /// 表示用のシリーズ名と、まとめるためのキー（正規化済み）
    static func make(title: String) -> (display: String, key: String) {
        var s = light(title)
        for (re, cut) in rules {
            let range = NSRange(s.startIndex..., in: s)
            if cut {
                // ここから後ろは回ごとに違う部分（話数・サブタイトル）なので切り落とす
                if let m = re.firstMatch(in: s, range: range), let r = Range(m.range, in: s) {
                    s = String(s[..<r.lowerBound])
                }
            } else {
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
            }
        }
        s = collapse(s)

        // 「番組名 サブタイトル（対戦カード・映画の題名など）」の形が多いので、最初の区切りより前を使う。
        // 前が短すぎる（「映画」「NHK」など）ときは、まとめすぎになるので使わない
        if let sp = s.firstIndex(of: " ") {
            let head = String(s[..<sp])
            if head.count >= 4 { s = head }
        }
        // シーズンの年（…中継2026）は外す（毎年同じ番組を 1 つにまとめる）
        if let re = yearSuffix, let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range, in: s), s.distance(from: s.startIndex, to: r.lowerBound) >= 2 {
            s = String(s[..<r.lowerBound])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " !-~:・"))
        if s.isEmpty { s = collapse(light(title)) }
        return (s, UsenetCatalog.normalize(s))
    }

    /// 全角英数記号→半角・全角空白→空白だけ（表示に使うので、かなや大文字小文字はそのまま）
    private static func light(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            var v = u.value
            if v == 0x3000 { v = 0x20 } else if (0xFF01...0xFF5E).contains(v) { v -= 0xFEE0 }
            if let n = Unicode.Scalar(v) { out.append(n) }
        }
        return String(out)
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func re(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// (パターン, true = そこから後ろを切る / false = その部分だけ消す)。上から順に当てる
    private static let rules: [(NSRegularExpression, Bool)] = [
        // 括弧の中は回ごとのサブタイトル・告知が多い
        ("【[^】]*】", false),
        ("「[^」]*」.*$", true),
        ("<[^>]*>", false),
        ("〈[^〉]*〉", false),
        // 日付（(5.27) 5/27 5月27日 と曜日）
        ("\\(\\s*\\d{1,2}\\s*[./．]\\s*\\d{1,2}\\s*\\)", false),
        ("\\d{1,2}\\s*/\\s*\\d{1,2}(\\s*\\([^)]{1,3}\\))?", false),
        ("\\d{1,2}月\\d{1,2}日(\\s*\\([^)]{1,3}\\))?", false),
        // サブタイトルの区切り記号
        ("[▽▼◇◆▼◎●○■□]", true),
        // 話数
        ("\\s*#\\s*\\d+", true),
        ("\\s*第\\s*[0-9一二三四五六七八九十百千]+\\s*(話|回|夜|部|章|節|弾|集|週|期)", true),
        ("\\s*(ep|episode|vol|story|stage|act)\\.?\\s*\\d+", true),
        ("\\s*\\(\\s*\\d{1,4}\\s*\\)", true),
        // 1 文字のもの（終・新・再）は前に空白があるときだけ（「明治維新」の「新」を消さないように）
        ("\\s*(最終回|最終話)\\s*$", false),
        ("\\s+(終|新|再)\\s*$", false),
        ("\\s+\\d{1,3}\\s*$", false),
    ].compactMap { pattern, cut in re(pattern).map { ($0, cut) } }

    private static let yearSuffix = re("\\s*(19|20)\\d{2}\\s*$")
}
