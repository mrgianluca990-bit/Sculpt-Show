import SwiftUI
import WebKit
import AppKit

@MainActor final class UserGuideBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    let url: URL?
    override init() {
        let bundled = Bundle.main.url(forResource:"SCULPT_SHOW_GUIDA_UTENTE_IT",withExtension:"html")
        let development = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/SCULPT_SHOW_GUIDA_UTENTE_IT.html")
        url = bundled ?? (FileManager.default.fileExists(atPath:development.path) ? development : nil)
        let configuration = WKWebViewConfiguration(); configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame:.zero,configuration:configuration)
        super.init(); web.navigationDelegate = self
        if let url { web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
        else { web.loadHTMLString("<h1>Guida italiana non disponibile</h1><p>Reinstallare il pacchetto completo di SCULPT SHOW.</p>",baseURL:nil) }
    }
    func navigationAction(_ action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        guard let target = action.request.url else { decisionHandler(.cancel); return }
        if target.isFileURL || target.scheme == "about" { decisionHandler(.allow) }
        else { if action.navigationType == .linkActivated { NSWorkspace.shared.open(target) }; decisionHandler(.cancel) }
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) { self.navigationAction(navigationAction,decisionHandler:decisionHandler) }
    func find(_ text:String) { guard !text.isEmpty else { return }; let options=WKFindConfiguration(); options.wraps=true; web.find(text,configuration:options) { _ in } }
}
struct UserGuideView: View {
    @StateObject private var browser = UserGuideBrowser()
    @State private var query = ""
    var body: some View {
        VStack(spacing:8) {
            HStack {
                TextField("Cerca nella guida…",text:$query).textFieldStyle(.roundedBorder).onSubmit { browser.find(query) }
                Button("Trova") { browser.find(query) }
                Button("Apri nel browser / stampa") { if let url=browser.url { NSWorkspace.shared.open(url) } }.disabled(browser.url == nil)
            }.padding([.horizontal,.top],12)
            GuideWebView(web:browser.web)
        }.frame(minWidth:660,minHeight:500)
    }
}
private struct GuideWebView:NSViewRepresentable {
    let web:WKWebView
    func makeNSView(context:Context)->WKWebView { web }
    func updateNSView(_ view:WKWebView,context:Context) {}
}
