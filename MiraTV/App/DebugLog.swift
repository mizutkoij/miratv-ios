import Foundation
import UIKit

/// 実機の不具合調査用ログ。1 秒ごとに homeserver の chapterd（POST /log）へまとめて送る。
/// 設定の「デバッグログを送る」で止められる。パスワード類は扱っていない
enum DebugLog {
    static let build = "ci64"
    private static let lock = NSLock()
    private static var buffer: [String] = []
    private static var timer: Timer?
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "debugLog") as? Bool ?? true
    }

    private static var endpoint: URL? {
        let s = (UserDefaults.standard.string(forKey: "chapterURL") ?? Defaults.chapterURL).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return URL(string: s)?.appending(path: "log")
    }

    /// 端末の中だけに残す直近のログ（設定 › 診断で見る。送信をオフにしていても残す）
    private static var recentLines: [String] = []
    static var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return recentLines
    }
    /// 前回のセッションが正常に終わらなかった（起動時に分かる）
    private(set) static var previousSessionCrashed = false

    static func log(_ cat: String, _ msg: String) {
        let line = "\(fmt.string(from: Date())) [\(cat)] \(msg)"
        lock.lock()
        recentLines.append(line)
        if recentLines.count > 400 { recentLines.removeFirst(100) }
        lock.unlock()
        guard enabled else { return }
        lock.lock()
        buffer.append(line)
        if buffer.count > 2000 { buffer.removeFirst(500) }   // 送れない間に膨らみ続けないように
        lock.unlock()
    }

    /// アプリ起動時に 1 回呼ぶ。送信タイマー・メインスレッド監視・メモリ監視・異常終了の検出を始める
    static func start() {
        let d = UserDefaults.standard
        if d.bool(forKey: "dbgRunning") {
            previousSessionCrashed = true
            log("app", "前回のセッションは正常に終わっていません（クラッシュ / メモリ不足による強制終了 / 強制終了操作）。最後の状態: \(d.string(forKey: "dbgLastPhase") ?? "?")")
        }
        d.set(true, forKey: "dbgRunning")
        let dev = UIDevice.current
        log("app", "起動 build=\(build) \(dev.model) iOS \(dev.systemVersion)")
        NSSetUncaughtExceptionHandler { e in
            DebugLog.log("crash", "未処理の例外 \(e.name.rawValue): \(e.reason ?? "") \(e.callStackSymbols.prefix(8).joined(separator: " | "))")
            DebugLog.flush(wait: true)
        }
        DispatchQueue.main.async {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in flush(wait: false) }
            NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                log("mem", "メモリ警告 footprint=\(footprintMB()) MB")
            }
        }
        startWatchdog()
    }

    static func phase(_ name: String) {
        UserDefaults.standard.set(name, forKey: "dbgLastPhase")
        if name == "background" { UserDefaults.standard.set(false, forKey: "dbgRunning") }
        if name == "active" { UserDefaults.standard.set(true, forKey: "dbgRunning") }
        log("app", "scenePhase=\(name) footprint=\(footprintMB()) MB")
        if name != "active" { flush(wait: false) }
    }

    /// メインスレッドが 1 秒以上返事をしない（= 固まっている）のを別スレッドから検出して記録する。5 秒おきにメモリも記録
    private static func startWatchdog() {
        let t = Thread {
            var tick = 0
            while true {
                let sem = DispatchSemaphore(value: 0)
                let t0 = Date()
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 1.0) == .timedOut {
                    log("hang", "メインスレッドが 1 秒以上応答なし footprint=\(footprintMB()) MB")
                    flush(wait: false)
                    sem.wait()
                    log("hang", String(format: "復帰 (%.1f 秒止まっていた)", Date().timeIntervalSince(t0)))
                }
                tick += 1
                if tick % 10 == 0 { log("mem", "footprint=\(footprintMB()) MB") }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        t.name = "debuglog-watchdog"; t.qualityOfService = .utility
        t.start()
    }

    /// 画面全体（アプリのウィンドウ）の絵を送る。AVSampleBufferDisplayLayer の映像は写らないことがある
    static func windowShot(_ name: String) {
        guard enabled else { return }
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return }
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 0.5
            let img = UIGraphicsImageRenderer(size: win.bounds.size, format: fmt).image { _ in
                win.drawHierarchy(in: win.bounds, afterScreenUpdates: false)
            }
            sendImage(img, name: name)
        }
    }

    static func sendImage(_ image: UIImage, name: String) {
        guard enabled, let png = image.pngData(), var comps = endpoint.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return }
        comps.path = "/shot"
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        req.httpBody = png
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
        log("shot", "\(name) \(png.count / 1024) KB 送信")
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    static func flush(wait: Bool) {
        lock.lock(); let lines = buffer; buffer.removeAll(); lock.unlock()
        guard !lines.isEmpty, enabled, let url = endpoint else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = lines.joined(separator: "\n").data(using: .utf8)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, res, err in
            if err != nil || ((res as? HTTPURLResponse)?.statusCode ?? 500) >= 400 {
                lock.lock(); buffer.insert(contentsOf: lines.suffix(500), at: 0); lock.unlock()   // 送れなければ次回に回す
            }
            sem.signal()
        }.resume()
        if wait { _ = sem.wait(timeout: .now() + 2) }
    }
}
