#if os(macOS)
import AppKit
import WebKit

public enum DiagramResult { case image(NSImage), failure(String) }

/// Draws Mermaid source to an image with a hidden web view that uses the bundled mermaid.js (no network).
/// Results are cached in memory and as PNGs on disk, keyed by source and theme.
@MainActor
public final class MermaidRenderer {
    public static let shared = MermaidRenderer(cacheFolder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Grimoire/diagrams"))

    private let cacheFolder: URL?
    private var memory: [String: NSImage] = [:]
    private var web: WKWebView?
    private var window: NSWindow?
    private var ready = false
    private var queue: [() async -> Void] = []
    private var busy = false

    public init(cacheFolder: URL?) { self.cacheFolder = cacheFolder }

    public func cachedImage(source: String, theme: Theme) -> NSImage? {
        let key = DiagramSource.key(source: source, theme: theme.name)
        if let m = memory[key] { return m }
        if let url = cacheFolder?.appendingPathComponent(key + ".png"), let img = NSImage(contentsOf: url) { memory[key] = img; return img }
        return nil
    }

    /// Renders (or fetches from cache). Calls are serialized: one diagram at a time in the shared web view.
    public func render(source: String, theme: Theme) async -> DiagramResult {
        if let img = cachedImage(source: source, theme: theme) { return .image(img) }
        return await withCheckedContinuation { cont in
            queue.append { [self] in cont.resume(returning: await draw(source: source, theme: theme)) }
            pump()
        }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        Task { @MainActor in await job(); busy = false; pump() }
    }

    private func draw(source: String, theme: Theme) async -> DiagramResult {
        let key = DiagramSource.key(source: source, theme: theme.name)
        guard await prepareWebView() , let web else { return .failure("diagram engine unavailable") }
        let c = theme.colors
        let vars: [String: String] = [
            "background": c.background, "primaryColor": c.surfaceRaised, "primaryTextColor": c.text, "primaryBorderColor": c.accent,
            "lineColor": c.textDim, "secondaryColor": c.surface, "tertiaryColor": c.surface, "textColor": c.text,
            "noteBkgColor": c.codeBackground, "noteTextColor": c.text, "mainBkg": c.surfaceRaised, "nodeBorder": c.accent,
            "clusterBkg": c.surface, "clusterBorder": c.border, "edgeLabelBackground": c.background, "fontFamily": "-apple-system, Helvetica, sans-serif",
        ]
        do {
            let result = try await web.callAsyncJavaScript("""
                mermaid.initialize({ startOnLoad: false, theme: 'base', themeVariables: vars, flowchart: { htmlLabels: false }, securityLevel: 'strict' });
                try {
                  const out = await mermaid.render('d' + Date.now(), src);
                  document.body.innerHTML = out.svg;
                  const el = document.querySelector('svg');
                  const r = el.getBoundingClientRect();
                  return JSON.stringify({ w: Math.ceil(r.width), h: Math.ceil(r.height) });
                } catch (e) { return JSON.stringify({ error: String(e && e.message || e) }); }
                """, arguments: ["src": source, "vars": vars], in: nil, contentWorld: .page)
            guard let s = result as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return .failure("no result") }
            if let e = d["error"] as? String { return .failure(e.components(separatedBy: "\n").first ?? e) }
            let w = max(40, d["w"] as? Double ?? 300), h = max(30, d["h"] as? Double ?? 200)
            web.frame = NSRect(x: 0, y: 0, width: w, height: h)
            window?.setContentSize(NSSize(width: w, height: h))
            try? await Task.sleep(nanoseconds: 60_000_000)
            let cfg = WKSnapshotConfiguration(); cfg.rect = NSRect(x: 0, y: 0, width: w, height: h); cfg.afterScreenUpdates = true
            let img = try await web.takeSnapshot(configuration: cfg)
            memory[key] = img
            if let folder = cacheFolder, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? png.write(to: folder.appendingPathComponent(key + ".png"))
            }
            return .image(img)
        } catch {
            return .failure("\(error.localizedDescription)")
        }
    }

    /// One long-lived web view in a window that is never shown.
    private func prepareWebView() async -> Bool {
        if ready { return true }
        guard let js = Bundle.module.url(forResource: "mermaid.min", withExtension: "js"), let script = try? String(contentsOf: js, encoding: .utf8) else { return false }
        let cfg = WKWebViewConfiguration()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        let win = NSWindow(contentRect: w.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = w
        win.isReleasedWhenClosed = false
        win.alphaValue = 0; win.ignoresMouseEvents = true
        web = w; window = win
        let loader = LoadWaiter()
        w.navigationDelegate = loader
        w.loadHTMLString("<!doctype html><html><body style='margin:0;background:transparent'></body></html>", baseURL: nil)
        await loader.wait()
        _ = try? await w.evaluateJavaScript(script)
        ready = ((try? await w.evaluateJavaScript("typeof mermaid")) as? String) == "object"
        return ready
    }
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<Void, Never>?
    private var done = false
    func wait() async { if done { return }; await withCheckedContinuation { cont = $0 } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true; cont?.resume(); cont = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true; cont?.resume(); cont = nil }
}
#endif
