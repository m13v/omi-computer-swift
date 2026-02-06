import SwiftUI
import WebKit

struct HelpPage: View {
    var body: some View {
        CrispWebView()
            .ignoresSafeArea()
    }
}

struct CrispWebView: NSViewRepresentable {
    private let websiteID = "0dcf3d1f-863d-4576-a534-31f2bb102ae5"

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body { margin: 0; padding: 0; background: transparent; }
            </style>
        </head>
        <body>
            <script>
                window.$crisp = [];
                window.CRISP_WEBSITE_ID = "\(websiteID)";
                (function(){
                    var d = document;
                    var s = d.createElement("script");
                    s.src = "https://client.crisp.chat/l.js";
                    s.async = 1;
                    d.getElementsByTagName("head")[0].appendChild(s);
                })();
            </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://omi.me"))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
