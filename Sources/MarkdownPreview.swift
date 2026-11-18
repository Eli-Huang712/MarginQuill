import SwiftUI
import WebKit

struct PreviewSection: Equatable {
    let id: String
    let markdown: String
}

struct PreviewAnnotation: Equatable {
    let id: UUID
    let section: String
    let number: Int
    let category: String
    let anchor: String?

    var payload: [String: Any] {
        ["id": id.uuidString, "section": section, "number": number, "category": category, "anchor": anchor ?? ""]
    }
}

struct PreviewFocus: Equatable {
    let page: UUID
    let issue: UUID
    let request = UUID()
}

struct MarkdownPreview: NSViewRepresentable {
    let sections: [PreviewSection]
    let annotations: [PreviewAnnotation]
    let focus: PreviewFocus?
    let openAnnotation: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "paperReview")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let html = Bundle.main.url(forResource: "preview", withExtension: "html") {
            context.coordinator.localURL = html
            view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view, sections: sections, annotations: annotations,
                                   dark: colorScheme == .dark, focus: focus, openAnnotation: openAnnotation)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "paperReview")
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var loaded = false
        var localURL: URL?
        private var sections: [PreviewSection] = []
        private var annotations: [PreviewAnnotation] = []
        private var dark = false
        private var focus: PreviewFocus?
        private var openAnnotation: ((UUID) -> Void)?
        private var renderedSections: [PreviewSection]?
        private var renderedAnnotations: [PreviewAnnotation]?
        private var renderedDark: Bool?
        private var appliedFocus: PreviewFocus?
        private var rendering = false

        func update(_ view: WKWebView, sections: [PreviewSection], annotations: [PreviewAnnotation],
                    dark: Bool, focus: PreviewFocus?, openAnnotation: @escaping (UUID) -> Void) {
            self.sections = sections
            self.annotations = annotations
            self.dark = dark
            self.focus = focus
            self.openAnnotation = openAnnotation
            render(view)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(webView)
        }

        private func render(_ view: WKWebView) {
            guard loaded, !rendering else { return }
            if sections == renderedSections, annotations == renderedAnnotations, dark == renderedDark {
                applyFocus(view)
                return
            }
            let rendered = sections
            let currentAnnotations = annotations
            let appearance = dark
            let data = rendered.map { ["id": $0.id, "markdown": $0.markdown] }
            rendering = true
            view.callAsyncJavaScript("await window.renderPaperNotes(pages, annotations, dark)", arguments: [
                "pages": data, "annotations": currentAnnotations.map(\.payload), "dark": appearance
            ], in: nil, in: .page) { [weak self, weak view] _ in
                guard let self, let view else { return }
                self.rendering = false
                self.renderedSections = rendered
                self.renderedAnnotations = currentAnnotations
                self.renderedDark = appearance
                self.appliedFocus = nil
                self.render(view)
            }
        }

        private func applyFocus(_ view: WKWebView) {
            guard appliedFocus != focus else { return }
            appliedFocus = focus
            view.callAsyncJavaScript("window.focusPaperAnnotation(page, issue)", arguments: [
                "page": focus?.page.uuidString ?? "", "issue": focus?.issue.uuidString ?? ""
            ], in: nil, in: .page, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "paperReview", message.frameInfo.isMainFrame,
                  let value = message.body as? String, let id = UUID(uuidString: value),
                  annotations.contains(where: { $0.id == id }) else { return }
            openAnnotation?(id)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL, url.standardizedFileURL == localURL?.standardizedFileURL {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
