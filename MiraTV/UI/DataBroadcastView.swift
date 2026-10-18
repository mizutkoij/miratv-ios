import SwiftUI
import WebKit

// データ放送（BML）。実装は web-bml (otya128/web-bml, MIT) のサーバーに任せ、
// アプリは WKWebView でそのページを透明に重ね、ARIB リモコンのキー（DESIGN.md「データ放送＋リモコン」）を送る。
// web-bml のページには各キーに対応した button（id="key18" 等）があるので、それをクリックして操作する。

/// ARIB のリモコンキー番号（web-bml の example/public/index.html の button id と同じ）
enum AribKey: Int {
    case up = 1, down = 2, left = 3, right = 4
    case n0 = 5, n1 = 6, n2 = 7, n3 = 8, n4 = 9, n5 = 10, n6 = 11, n7 = 12, n8 = 13, n9 = 14, n10 = 15, n11 = 16, n12 = 17
    case enter = 18, back = 19, d = 20
    case blue = 21, red = 22, green = 23, yellow = 24
}

enum BMLURL {
    /// 例: http://host:23234/channels/GR/27/stream?demultiplexServiceId=1024&format=null
    /// format=null は映像のエンコードをせず、データカルーセルだけをデコードする
    /// 録画（EPGStation の映像ファイル）のデータ放送。web-bml が `/videos/{id}` を EPGStation から読む
    static func make(base: URL, videoFileId: Int) -> URL? {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
        c?.path = "/videos/\(videoFileId)"
        c?.queryItems = [URLQueryItem(name: "format", value: "null")]
        return c?.url
    }

    static func make(base: URL, service: MirakurunService) -> URL? {
        guard let ch = service.channel else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let type = ch.type.addingPercentEncoding(withAllowedCharacters: allowed),
              let channel = ch.channel.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
        c?.path = "/channels/\(type)/\(channel)/stream"
        c?.queryItems = [URLQueryItem(name: "demultiplexServiceId", value: String(service.serviceId)),
                         URLQueryItem(name: "format", value: "null")]
        return c?.url
    }
}

final class BMLController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var lastKey = "—"
    @Published var status = "接続中…"
    @Published var isError = false
    /// BML の文書が読み込まれて、画面が出る状態になった（それまではアプリ側の映像を隠さない）
    @Published var ready = false
    /// BML が指定した映像の枠（BML 画面全体に対する 0〜1 の割合）。全画面のときは nil
    @Published var videoRect: CGRect?
    fileprivate weak var webView: WKWebView?
    private var lastReport = ""
    private var lastDom = ""
    private var lastVd = ""

    private var clearWork: DispatchWorkItem?
    /// ページ切り替えの途中は枠が一瞬消える。すぐ全画面に戻すとチラつくので、消えたままが 1.2 秒続いたときだけ戻す
    private func applyVideoRect(_ vr: CGRect?) {
        if let vr {
            clearWork?.cancel(); clearWork = nil
            if videoRect != vr { videoRect = vr }
        } else if videoRect != nil, clearWork == nil {
            let w = DispatchWorkItem { [weak self] in self?.videoRect = nil; self?.clearWork = nil }
            clearWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
        }
    }

    func press(_ key: AribKey, label: String) {
        lastKey = label
        let js = "(function(){var b=document.getElementById('key\(key.rawValue)');if(b){b.click();return 'ok'}return 'nobutton'})()"
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            if let r = result as? String, r == "nobutton" {
                DispatchQueue.main.async { self?.status = "ページが読み込まれていません" }
            }
        }
    }

    /// ページ内の JS が 1 秒ごとに送ってくる状態（受信した通知の数、サーバーに閉じられたか、BML の読み込み状況、JS のエラー）
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        let ws = d["ws"] as? [String: Int] ?? [:]
        let modules = ws["moduleDownloaded"] ?? 0
        let indicator = d["ind"] as? String ?? ""
        let err = d["err"] as? String ?? ""
        let closed = d["closed"] as? Int
        let drawn = d["drawn"] as? Bool ?? false
        if let vd = d["vdbg"] as? String, vd != lastVd { lastVd = vd; DebugLog.log("bml-vr", "vr=\(String(describing: d["vr"])) \(vd)") }
        let vr = (d["vr"] as? [Double]).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        DispatchQueue.main.async { self.applyVideoRect(vr) }
        if let dom = d["dom"] as? String, !dom.isEmpty, dom != lastDom { lastDom = dom; DebugLog.log("bml-dom", dom) }
        if let con = d["con"] as? [String] { for c in con { DebugLog.log("bml-js", c) } }
        let rep = "ws=\(ws) closed=\(closed.map(String.init) ?? "-") ind=\(indicator) err=\(err) bg=\(d["bg"] as? String ?? "") vid=\(d["vid"] as? Int ?? -1) h=\(d["h"] as? Int ?? -1) vis=\(d["vis"] as? String ?? "") drawn=\(drawn)"
        if rep != lastReport { lastReport = rep; DebugLog.log("bml", rep) }
        DispatchQueue.main.async {
            if !err.isEmpty && modules == 0 {
                self.status = "ページのエラー: \(err)"; self.isError = true
            } else if indicator.contains(".bml") && drawn {
                self.status = "データ放送を表示中"; self.isError = false; self.ready = true
            } else if indicator.contains(".bml") {
                // 文書は起動したが、何も描かれていない（放送側が条件を待っている）。映像は隠さない
                self.status = "データ放送は起動済みですが、いま表示できる内容がありません"; self.isError = false; self.ready = false
            } else if let closed, modules == 0 {
                self.status = "サーバーが接続を閉じました（コード \(closed)）。チューナーが使用中の可能性があります"; self.isError = true
            } else if modules > 0 {
                self.status = "データを受信中（\(modules) モジュール）"; self.isError = false
            } else if ws["videoStreamUrl"] != nil {
                self.status = "チューナーを起動中…"; self.isError = false
            } else if ws.isEmpty {
                self.status = "ページを読み込み中…"; self.isError = false
            } else {
                self.status = "接続中…"; self.isError = false
            }
        }
    }

    /// 調査用: WebView 単体の絵を homeserver に送る（透明部分は透明のまま）
    func snapshot(_ name: String) {
        guard DebugLog.enabled, let wv = webView else { return }
        wv.takeSnapshot(with: nil) { image, error in
            if let image { DebugLog.sendImage(image, name: name) } else { DebugLog.log("shot", "\(name) web snapshot failed: \(String(describing: error))") }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DebugLog.log("bml", "読み込み開始 \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { DebugLog.log("bml", "didCommit") }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.log("bml", "didFinish footprint=\(DebugLog.footprintMB()) MB")
    }

    /// 白い画面で固まる典型原因: WebKit のプロセスが落ちた（メモリ不足など）
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DebugLog.log("bml", "★WebContent プロセスが終了した（白画面の原因候補）footprint=\(DebugLog.footprintMB()) MB")
        DispatchQueue.main.async { self.status = "WebKit のプロセスが落ちました"; self.isError = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.log("bml", "didFail \(error)")
        DispatchQueue.main.async { self.status = describeError(error); self.isError = true }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DebugLog.log("bml", "didFailProvisional \(error)")
        DispatchQueue.main.async { self.status = describeError(error); self.isError = true }
    }
}

/// web-bml のページを 960×540 のまま縮小して透明に表示する
struct BMLWebView: UIViewRepresentable {
    let url: URL
    let controller: BMLController

    // ページの見出しとリモコン、<video> を隠し、960px 幅を画面幅に合わせて縮小する
    private static let injected = """
    (function(){
      var st=document.createElement('style');
      st.textContent='html,body{background:transparent!important;margin:0!important;overflow:hidden!important} h1,#remote-control{display:none!important} video{visibility:hidden!important}';
      document.head.appendChild(st);
      function fit(){var s=window.innerWidth/960;var e=document.documentElement;e.style.transformOrigin='0 0';e.style.transform='scale('+s+')';}
      fit();window.addEventListener('resize',fit);
      // web-bml のサーバーは、<video> が /streams/{id}.null を取りに来るまで受信を止めて待つ。
      // <video> は隠しているので、その要求をここで代わりに出して、データ放送の受信を始めさせる
      var started={};
      var lastD='';var dCount=0;var lastT=0;
      // BML が自分で出す 'invisible true/false'（データ放送が非表示か）を横取りして覚える。d は表示のON/OFFの切り替えなので、非表示のときだけ押す
      var oLog=console.log;console.log=function(){try{var s=Array.prototype.join.call(arguments,' ').trim();if(s==='invisible true')window.__inv=true;else if(s==='invisible false')window.__inv=false;}catch(x){}return oLog.apply(console,arguments);};
      setInterval(function(){
        // BML は起動しても d ボタンを押すまで画面が出ない（実測: NHK BS）。起動を検知したら 1 回だけ d を押す
        var ind=document.querySelector('.remote-control-indicator');
        var t=ind?(ind.textContent||'').trim():'';
        var m=/[^ ]*[.]bml/.exec(t);
        if(m&&t.indexOf('読み込み中')<0&&/startup[.]bml/.test(m[0])&&window.__inv===true&&(m[0]!==lastD||Date.now()-lastT>3000)&&dCount<12){lastD=m[0];lastT=Date.now();dCount++;var d=document.getElementById('key20');if(d)d.click();}
        document.querySelectorAll('video source').forEach(function(s){
          var u=s.src;
          if(u&&/[.]null$/.test(u)&&!started[u]){started[u]=1;fetch(u).catch(function(){});}
        });
      },500);
    })();
    """

    // BML の描画は外から触れない（closed）Shadow DOM の中。作られる瞬間に、映像の箱（<video>）を透明にする
    // スタイルを差し込む。文書の先頭（atDocumentStart）で attachShadow を差し替える必要がある
    private static let shadowPatch = """
    (function(){
      // 状態の報告用: 受信した WebSocket 通知の種類ごとの数・切断コード・JS のエラーを、1 秒ごとにアプリへ送る
      var Orig = window.WebSocket; window.__wsTypes = {};
      window.WebSocket = function(u, p){
        var ws = p ? new Orig(u,p) : new Orig(u);
        ws.addEventListener('message', function(e){
          try { var m = JSON.parse(e.data); window.__wsTypes[m.type] = (window.__wsTypes[m.type]||0) + 1; } catch(x) {}
        });
        ws.addEventListener('close', function(e){ window.__wsClosed = e.code; });
        return ws;
      };
      window.WebSocket.prototype = Orig.prototype;
      ['CONNECTING','OPEN','CLOSING','CLOSED'].forEach(function(k){ window.WebSocket[k] = Orig[k]; });
      window.__con = [];
      ['log','warn','error'].forEach(function(k){ var o = console[k]; console[k] = function(){ try { var txt = Array.prototype.map.call(arguments, function(a){ return String(a); }).join(' ').slice(0, 300); if (!/detectComponent|setInterval chkRen|BinaryTable|ModuleLocked|lockModule|unlockModule|ModuleUpdated/.test(txt)) window.__con.push(k + ': ' + txt); if (window.__con.length > 30) window.__con.shift(); } catch(x) {} return o.apply(console, arguments); }; });
      window.addEventListener('error', function(e){ window.__lastErr = String(e.message || e.type); });
      window.addEventListener('unhandledrejection', function(e){ window.__lastErr = String(e.reason); });
      setInterval(function(){
        var ind = document.querySelector('.remote-control-indicator');
        try { var drawn = false; try { (window.__roots || []).forEach(function(r){ Array.prototype.forEach.call(r.children, function(c){ if (c.tagName === 'STYLE') return; if (getComputedStyle(c).visibility === 'hidden') return; if (c.querySelector('img,object,input,textarea') || (c.textContent || '').trim().length > 0) drawn = true; }); }); } catch(x) {} var dom = ''; try { if ((window.__n = (window.__n || 0) + 1) % 8 === 1) { var cx = innerWidth / 2, cy = innerHeight / 2; dom = 'win=' + innerWidth + 'x' + innerHeight + ' tf=' + document.documentElement.style.transform + ' htmlbg=' + getComputedStyle(document.documentElement).backgroundColor; (window.__roots || []).forEach(function(r, i){ var el = r.elementFromPoint(cx, cy); var d = function(e){ if (!e) return 'none'; var cs = getComputedStyle(e), b = e.getBoundingClientRect(); return e.tagName + (e.className ? '.' + e.className : '') + '{bg=' + cs.backgroundColor + ' op=' + cs.opacity + ' vis=' + cs.visibility + ' ' + Math.round(b.width) + 'x' + Math.round(b.height) + '}'; }; var kids = Array.prototype.filter.call(r.children, function(c){ return c.tagName !== 'STYLE'; }).slice(0, 4).map(d).join(' '); dom += ' | root' + i + ' centre=' + d(el) + ' kids=' + kids; var h = r.children[r.children.length - 1]; var body = h && h.querySelector ? h.querySelector('body') : null; if (body) { var sub = Array.prototype.slice.call(body.children, 0, 8).map(d).join(' '); dom += ' body=' + d(body) + ' nbody=' + body.children.length + ' sub=' + sub + ' inner=' + (r.innerHTML || '').length; } }); } } catch(x) { dom = 'domerr ' + x; } var vr = []; var vdbg = ''; try { if (drawn) { (window.__roots || []).forEach(function(r){ Array.prototype.forEach.call(r.querySelectorAll('video,.arib-video-container'), function(c){ var b = c.getBoundingClientRect(); vdbg += c.tagName + '.' + (c.className || '') + ':' + Math.round(b.left) + ',' + Math.round(b.top) + ',' + Math.round(b.width) + 'x' + Math.round(b.height) + ' '; var hb = (r.children[r.children.length - 1] || {}).getBoundingClientRect ? r.children[r.children.length - 1].getBoundingClientRect() : null; if (hb && hb.width > 0 && hb.height > 0 && b.width > 40 && b.height > 40 && b.width < hb.width * 0.95) vr = [(b.left - hb.left) / hb.width, (b.top - hb.top) / hb.height, b.width / hb.width, b.height / hb.height]; }); }); } } catch(x) {} var con = window.__con; window.__con = []; var bgc = ''; try { bgc = getComputedStyle(document.body).backgroundColor; } catch(x) {} window.webkit.messageHandlers.mira.postMessage({ ws: window.__wsTypes, closed: window.__wsClosed, ind: ind ? ind.textContent : '', err: window.__lastErr || '', con: con, vr: vr, vdbg: vdbg, dom: dom, drawn: drawn, bg: bgc, vid: document.querySelectorAll('video').length, h: document.documentElement.scrollHeight, vis: document.visibilityState }); } catch(x) {}
      }, 250);
    })();
    (function(){
      var orig = Element.prototype.attachShadow;
      Element.prototype.attachShadow = function(init) {
        var root = orig.call(this, init);
        try { var st = document.createElement('style'); st.textContent = 'video{visibility:hidden!important}'; root.appendChild(st); } catch (e) {}
        (window.__roots = window.__roots || []).push(root);
        return root;
      };
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.userContentController.add(controller, name: "mira")
        conf.userContentController.addUserScript(
            WKUserScript(source: Self.shadowPatch, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []   // muted autoplay の <video> を動かすため
        conf.userContentController.addUserScript(
            WKUserScript(source: Self.injected, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        // ページの外側（下地）の色。既定だと白/黒の不透明な板が敷かれ、透明にしたはずのデータ放送が全面塗りつぶされる疑い
        wv.underPageBackgroundColor = .clear
        #if compiler(>=6.2)
        // iOS 26 のスクロール端エフェクト（ページ色を端に引き延ばす不透明なぼかし）を切る
        if #available(iOS 26.0, *) {
            wv.scrollView.topEdgeEffect.isHidden = true
            wv.scrollView.bottomEdgeEffect.isHidden = true
            wv.scrollView.leftEdgeEffect.isHidden = true
            wv.scrollView.rightEdgeEffect.isHidden = true
        }
        #endif
        wv.navigationDelegate = controller
        controller.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// DESIGN.md のリモコン: 色ボタン 4 つ / 戻る・d / 十字キー / 数字 1〜12
struct AribRemote: View {
    @ObservedObject var controller: BMLController

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                color(.blue, "青", Theme.C.aribBlue, .white)
                color(.red, "赤", Theme.C.aribRed, .white)
                color(.green, "緑", Theme.C.aribGreen, .white)
                color(.yellow, "黄", Theme.C.aribYellow, Theme.C.onAribYellow)
            }
            HStack(alignment: .center) {
                VStack(spacing: 10) {
                    wide(.back, "戻る", accent: false)
                    wide(.d, "d", accent: true)
                }
                Spacer()
                dpad
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(Array(zip(1...12, numberKeys)), id: \.0) { n, key in
                    Button { controller.press(key, label: String(n)) } label: {
                        Text(String(n)).font(Theme.F.mono(15))
                            .foregroundStyle(Theme.C.text)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.C.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.C.border))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private let numberKeys: [AribKey] = [.n1, .n2, .n3, .n4, .n5, .n6, .n7, .n8, .n9, .n10, .n11, .n12]

    private func color(_ key: AribKey, _ label: String, _ bg: Color, _ fg: Color) -> some View {
        Button { controller.press(key, label: label) } label: {
            Text(label).font(Theme.F.jp(14, .bold)).foregroundStyle(fg)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(bg, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func wide(_ key: AribKey, _ label: String, accent: Bool) -> some View {
        Button { controller.press(key, label: label) } label: {
            Text(label).font(Theme.F.jp(14, .bold))
                .foregroundStyle(accent ? Theme.C.accent : Theme.C.text2)
                .frame(width: 72, height: 44)
                .background(Theme.C.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent ? Theme.C.accent : Theme.C.borderStrong))
        }
        .buttonStyle(.plain)
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(Theme.C.surface).overlay(Circle().stroke(Theme.C.border))
            VStack {
                arrow("chevron.up", .up, "↑")
                Spacer()
                arrow("chevron.down", .down, "↓")
            }
            HStack {
                arrow("chevron.left", .left, "←")
                Spacer()
                arrow("chevron.right", .right, "→")
            }
            Button { controller.press(.enter, label: "決定") } label: {
                Text("決定").font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.onAccent)
                    .frame(width: 68, height: 68).background(Theme.C.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 176, height: 176)
    }

    private func arrow(_ symbol: String, _ key: AribKey, _ label: String) -> some View {
        Button { controller.press(key, label: label) } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.C.text2).frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .padding(4)
    }
}
