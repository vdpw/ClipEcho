import AppKit
import ClipEchoCore
import WebKit

/// The original renderer runs only as an app-owned user script in an inert,
/// nonpersistent document. Clipboard HTML never becomes an executable document.
@MainActor
final class HistoryHTMLPreviewView: NSView, WKNavigationDelegate, WKUIDelegate {
  private var web: WKWebView!
  private(set) var previewHeight: CGFloat = 280
  var onHeightChanged: (() -> Void)?
  private var rendered = false
  override var isFlipped: Bool { true }
  init(html: String, title: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.borderWidth = 1
    layer?.borderColor = HistoryVisual.separator(self).cgColor
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let input = (try? String(data: JSONEncoder().encode(html), encoding: .utf8)) ?? "\"\""
    let script =
      "if (!window.__clipechoPreviewApplied) { window.__clipechoPreviewApplied = true;\n"
      + OriginalHTMLPreviewSource.javascript + "\nconst preview=buildHtmlPreview(" + input
      + "); document.open(); document.write(preview.srcDoc); document.close(); window.webkit.messageHandlers.clipechoPreview.postMessage(preview.compact); }"
    configuration.userContentController.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    web = WKWebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.setAccessibilityLabel(title)
    addSubview(web)
    configuration.userContentController.add(
      HistoryHTMLMessageRelay(owner: self), name: "clipechoPreview")
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "ClipEchoPreviewDenyAllResources",
      encodedContentRuleList:
        "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]"
    ) { [weak self] rule, error in
      DispatchQueue.main.async {
        guard let self, let rule, error == nil else { return }
        configuration.userContentController.add(rule)
        self.web.loadHTMLString(
          "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'none'; script-src 'none'; style-src 'sha256-SiMZoSATeAIpEWcOtJfnKFGWw/iEtsUerrNtbtJdbmA='; base-uri 'none'; form-action 'none'\"></head><body></body></html>",
          baseURL: nil)
      }
    }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    web.frame = bounds
  }
  fileprivate func receive(_ message: WKScriptMessage) {
    guard message.name == "clipechoPreview", let compact = message.body as? Bool else { return }
    rendered = true
    let height: CGFloat = compact ? 104 : 280
    if height != previewHeight {
      previewHeight = height
      onHeightChanged?()
    }
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(
      navigationAction.request.url?.absoluteString == "about:blank"
        && navigationAction.navigationType == .other ? .allow : .cancel)
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? { nil }
  override func mouseDown(with event: NSEvent) {}

  struct DiagnosticSnapshot: Sendable {
    let text: String
    let height: CGFloat
    let unsafeElementCount: Int
    let unsafeAttributeCount: Int
    let csp: String
    let fontFamily: String
    let headerBorderBottomStyle: String
  }

  /// The caller supplies a synthetic HTML fixture. No production clipboard data
  /// is logged or exported by this inspection-only self-test API.
  func diagnosticSnapshot() async throws -> DiagnosticSnapshot {
    let deadline = Date().addingTimeInterval(15)
    while !rendered && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    guard rendered else { throw StorageError.invalidEvent }
    return try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(
        "({text:document.body.textContent,fontFamily:getComputedStyle(document.body).fontFamily,headerBorderBottomStyle:getComputedStyle(document.querySelector('h1,h2,h3,h4,h5,h6')||document.body).borderBottomStyle,unsafeElements:document.querySelectorAll('script,iframe,object,embed,style:not(head>style)').length,unsafeAttributes:Array.from(document.querySelectorAll('*')).reduce((n,e)=>n+Array.from(e.attributes).filter(a=>/^(?:src|href|style|on)/i.test(a.name)).length,0),csp:document.querySelector('meta[http-equiv=\\\"Content-Security-Policy\\\"]').content})"
      ) { [weak self] value, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let self, let result = value as? [String: Any], let text = result["text"] as? String,
          let csp = result["csp"] as? String
        else {
          continuation.resume(throwing: StorageError.invalidEvent)
          return
        }
        continuation.resume(
          returning: DiagnosticSnapshot(
            text: text, height: previewHeight,
            unsafeElementCount: (result["unsafeElements"] as? NSNumber)?.intValue ?? -1,
            unsafeAttributeCount: (result["unsafeAttributes"] as? NSNumber)?.intValue ?? -1,
            csp: csp, fontFamily: result["fontFamily"] as? String ?? "",
            headerBorderBottomStyle: result["headerBorderBottomStyle"] as? String ?? ""))
      }
    }
  }
}

@MainActor
private final class HistoryHTMLMessageRelay: NSObject, WKScriptMessageHandler {
  weak var owner: HistoryHTMLPreviewView?
  init(owner: HistoryHTMLPreviewView) { self.owner = owner }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) { owner?.receive(message) }
}
