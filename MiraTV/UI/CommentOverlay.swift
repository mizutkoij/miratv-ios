import SwiftUI
import UIKit

/// 実況コメントを右から左へ流す（ニコニコ風）。映像と同じ大きさに重ね、操作は下へ通す。
/// UIKit のラベルを並べて、決まった速さで横に動かすだけ（文字の長さに関係なく約 5 秒で画面を横切る）
struct CommentOverlay: UIViewRepresentable {
    @ObservedObject var controller: CommentController
    var opacity: Double = 0.9

    func makeUIView(context: Context) -> CommentCanvas {
        let v = CommentCanvas()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        controller.sink = { [weak v] c in v?.show(c) }
        controller.clear = { [weak v] in v?.removeAll() }
        return v
    }

    func updateUIView(_ v: CommentCanvas, context: Context) {
        v.alpha = opacity
        controller.sink = { [weak v] c in v?.show(c) }
        controller.clear = { [weak v] in v?.removeAll() }
    }

    static func dismantleUIView(_ v: CommentCanvas, coordinator: ()) {
        v.removeAll()
    }
}

final class CommentCanvas: UIView {
    private static let lanes = 11
    private static let crossSeconds: Double = 5.0
    private static let fixedSeconds: Double = 3.0
    private static let maxOnScreen = 70

    /// 各段（行）が次のコメントを受けられるようになる時刻（前のコメントの尻尾が右端から出た時刻）
    private var laneFree = [CFTimeInterval](repeating: 0, count: lanes)
    private var fixedTopFree = [CFTimeInterval](repeating: 0, count: lanes)
    private var fixedBottomFree = [CFTimeInterval](repeating: 0, count: lanes)
    /// 各段の前のコメントが左端へ消える時刻（長いコメントは速いので、短い前のコメントに追いつかないか見る）
    private var laneEnd = [CFTimeInterval](repeating: 0, count: lanes)

    func removeAll() {
        subviews.forEach { $0.layer.removeAllAnimations(); $0.removeFromSuperview() }
        laneFree = .init(repeating: 0, count: Self.lanes)
        laneEnd = laneFree
        fixedTopFree = laneFree
        fixedBottomFree = laneFree
    }

    func show(_ c: JikkyoComment) {
        guard bounds.width > 40, bounds.height > 40, subviews.count < Self.maxOnScreen else { return }
        let cmds = Set(c.mail.lowercased().split(separator: " ").map(String.init))
        let laneH = bounds.height / CGFloat(Self.lanes)
        var fontSize = laneH * 0.8
        if cmds.contains("big") { fontSize *= 1.35 } else if cmds.contains("small") { fontSize *= 0.7 }

        let label = UILabel()
        label.text = c.text.replacingOccurrences(of: "\n", with: " ")
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.textColor = Self.color(cmds)
        // 縁取りの代わりに影（明るい映像の上でも読めるように）
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 1.5
        label.layer.shadowOffset = .zero
        label.sizeToFit()
        let w = label.bounds.width, h = label.bounds.height
        let now = CACurrentMediaTime()

        if cmds.contains("ue") || cmds.contains("shita") {
            let bottom = cmds.contains("shita")
            var free = bottom ? fixedBottomFree : fixedTopFree
            guard let lane = free.firstIndex(where: { $0 <= now }) else { return }
            free[lane] = now + Self.fixedSeconds
            if bottom { fixedBottomFree = free } else { fixedTopFree = free }
            let y = bottom ? bounds.height - laneH * CGFloat(lane + 1) : laneH * CGFloat(lane)
            label.frame = CGRect(x: (bounds.width - w) / 2, y: y + (laneH - h) / 2, width: w, height: h)
            addSubview(label)
            UIView.animate(withDuration: 0.15, delay: Self.fixedSeconds, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
            return
        }

        // 流れるコメント: 段ごとに、前のコメントと重ならない最初の段を使う。空きが無ければいちばん早く空く段
        let W = bounds.width
        let speed = (W + w) / Self.crossSeconds          // pt/s
        // 入れてよい段: 前のコメントの尻尾が右端から出ていて、かつ自分（速いかもしれない）が左端に着くまでに
        // 前のコメントが左端へ消えている段
        let reachLeftEdge = now + Self.crossSeconds * Double(W / (W + w))
        let ok: (Int) -> Bool = { self.laneFree[$0] <= now && reachLeftEdge >= self.laneEnd[$0] }
        let lane = laneFree.indices.first(where: ok) ?? laneFree.indices.min { laneFree[$0] < laneFree[$1] }!
        laneFree[lane] = now + Double((w + 24) / speed)            // 尻尾が右端から出るまで次は入れない
        laneEnd[lane] = now + Self.crossSeconds
        label.frame = CGRect(x: bounds.width, y: laneH * CGFloat(lane) + (laneH - h) / 2, width: w, height: h)
        addSubview(label)
        UIView.animate(withDuration: Self.crossSeconds, delay: 0, options: [.curveLinear], animations: {
            label.frame.origin.x = -w
        }) { _ in
            label.removeFromSuperview()
        }
    }

    private static func color(_ cmds: Set<String>) -> UIColor {
        let table: [String: UInt32] = [
            "red": 0xFF0000, "pink": 0xFF8080, "orange": 0xFFC000, "yellow": 0xFFFF00, "green": 0x00FF00,
            "cyan": 0x00FFFF, "blue": 0x0000FF, "purple": 0xC000FF, "black": 0x000000,
        ]
        for (k, v) in table where cmds.contains(k) {
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        if let hex = cmds.first(where: { $0.hasPrefix("#") && $0.count == 7 }), let v = UInt32(hex.dropFirst(), radix: 16) {
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return .white
    }
}
