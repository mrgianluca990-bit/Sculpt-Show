import AppKit
import WebKit
@testable import SculptShowApp
@main struct UserGuideProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let guide = UserGuideBrowser()
        guard let url = guide.url, url.isFileURL else { fatalError("Missing offline guide") }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = guide.web; window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<200 { if guide.web.title?.contains("Guida utente italiana") == true && !guide.web.isLoading { break }; try await Task.sleep(nanoseconds:50_000_000) }
        guard guide.web.title?.contains("1.0.0") == true else { fatalError("Guide HTML did not load: \(guide.web.title ?? "nil")") }
        print("PASS · offline Italian guide renders inside real WKWebView")
        let found: Bool = await withCheckedContinuation { done in guide.web.find("IN/OUT",configuration:WKFindConfiguration()) { done.resume(returning:$0.matchFound) } }
        guard found else { fatalError("Guide search failed") }
        print("PASS · internal guide search finds documented IN/OUT")
        let source = try String(contentsOf:url,encoding:.utf8)
        guard source.contains("id=\"cap-24\"") && source.contains("lang=\"it\"") && !source.contains("<script") else { fatalError("Guide structure incomplete") }
        print("PASS · 24 chapters, Italian metadata and script-free offline content")
        print("ALL USER GUIDE CHECKS PASSED")
    }
}
