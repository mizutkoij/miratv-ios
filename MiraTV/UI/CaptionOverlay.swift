import SwiftUI
import WebKit

// ARIB 字幕（STD-B24）の表示。
// 字幕のパケットは TSPipeline が映像と同じ TS から取り出し、PlayerEngine が映像の時計に合わせて渡してくる。
// 文字の解釈と描画（外字・DRCS・色・縁取り）は aribb24.js（MIT, monyone）の CanvasProvider に任せ、
// 透明な WKWebView の canvas に描く。ライブラリは Resources/Captions/aribb24-embedded.js（外字のグリフ入り）を同梱している。

final class CaptionController: NSObject, ObservableObject {
    fileprivate weak var webView: WKWebView?

    /// PTS の順に並んだ字幕パケット（data_identifier 0x80 から始まる PES のペイロード）を渡す
    func feed(_ packets: [Data]) {
        guard let webView, !packets.isEmpty else { return }
        let list = packets.map { "\"\($0.base64EncodedString())\"" }.joined(separator: ",")
        webView.evaluateJavaScript("window.miraCaptions&&window.miraCaptions([\(list)])")
    }

    func clear() {
        webView?.evaluateJavaScript("window.miraClear&&window.miraClear()")
    }
}

struct CaptionOverlay: UIViewRepresentable {
    let controller: CaptionController

    /// 960×540 の canvas を画面いっぱいに伸ばして置く。ARIB の字幕は 960×540 の座標で作られている
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
    <style>html,body{margin:0;background:transparent;overflow:hidden;height:100%}
    canvas{position:fixed;left:0;top:0;width:100%;height:100%}</style></head><body>
    <canvas id="c" width="960" height="540"></canvas>
    <script>
    (function(){
      var canvas=document.getElementById('c'), ctx=canvas.getContext('2d');
      var opt={data_identifier:0x80,data_group_id:0x01};
      var timer=null;
      function clearNow(){ctx.clearRect(0,0,960,540);}
      window.miraClear=function(){ if(timer){clearTimeout(timer);timer=null;} clearNow(); };
      window.miraCaptions=function(list){
        if(!window.aribb24js) return;
        list.forEach(function(b64){
          var bin=atob(b64), u=new Uint8Array(bin.length);
          for(var i=0;i<bin.length;i++)u[i]=bin.charCodeAt(i);
          // 字幕の本文ではないデータ（字幕管理データなど）では表示を消さない
          if(!aribb24js.CanvasProvider.detect(u,opt)) return;
          clearNow();
          var res=new aribb24js.CanvasProvider(u,0).render(Object.assign({},opt,{canvas:canvas,width:960,height:540}));
          if(timer){clearTimeout(timer);timer=null;}
          // 消去の字幕が届かなかったときに残り続けないよう、15 秒で消す
          if(res&&res.rendered){timer=setTimeout(clearNow,15000);}
        });
      };
    })();
    </script></body></html>
    """

    private static func library() -> String {
        if let url = Bundle.main.url(forResource: "aribb24-embedded", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return ""
    }

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.userContentController.addUserScript(
            WKUserScript(source: Self.library(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.isUserInteractionEnabled = false
        controller.webView = wv
        wv.loadHTMLString(Self.page, baseURL: nil)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
