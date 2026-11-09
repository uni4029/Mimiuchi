import AppKit
import MimiuchiCore
import SwiftUI

/// Owns only weak references to the native scroll views, shared by one translator surface.
@MainActor
final class ScrollLink {
    private weak var source: LinkedScrollView?
    private weak var translation: LinkedScrollView?
    private var state = ScrollSynchronization()
    private var applying = false

    func attach(_ view: LinkedScrollView, pane: ScrollSynchronization.Pane) {
        switch pane {
        case .source: source = view
        case .translation: translation = view
        }
        view.link = self
        view.pane = pane
        geometryChanged(view)
    }

    func detach(_ view: LinkedScrollView) {
        view.link = nil
        guard scrollView(for: view.pane) === view else { return }
        state.remove(view.pane)
        switch view.pane {
        case .source: source = nil
        case .translation: translation = nil
        }
    }

    func setEnabled(_ enabled: Bool) { apply(state.setEnabled(enabled)) }
    func reset() { apply(state.reset()) }

    func geometryChanged(_ view: LinkedScrollView) {
        guard scrollView(for: view.pane) === view, let document = view.documentView else { return }
        let metrics = ScrollSynchronization.Metrics(
            offset: view.contentView.bounds.minY,
            contentHeight: document.frame.height,
            viewportHeight: view.contentView.bounds.height)
        let destinations = state.update(metrics, for: view.pane, programmatic: applying)
        if !applying { apply(destinations) }
    }

    private func scrollView(for pane: ScrollSynchronization.Pane) -> LinkedScrollView? {
        pane == .source ? source : translation
    }

    private func apply(_ destinations: [ScrollSynchronization.Pane: Double]) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        for (pane, offset) in destinations {
            guard let view = scrollView(for: pane), abs(view.contentView.bounds.minY - offset) > 0.5 else { continue }
            view.contentView.scroll(to: NSPoint(x: 0, y: offset))
            view.reflectScrolledClipView(view.contentView)
        }
    }
}

class LinkedScrollView: NSScrollView {
    weak var link: ScrollLink?
    var pane: ScrollSynchronization.Pane = .source

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        link?.geometryChanged(self)
    }

    override func layout() {
        super.layout()
        if let editor = documentView as? NSTextView, let container = editor.textContainer {
            // Lay out the whole document so lazy text layout does not underestimate
            // the scroll range for long input or after a width change.
            editor.layoutManager?.ensureLayout(for: container)
        }
        link?.geometryChanged(self)
    }
}

/// Hosting the document at the clip view's width gives us real wrapped-text heights,
/// including selectable SwiftUI text, without inspecting SwiftUI's private view hierarchy.
struct LinkedScrollContent<Content: View>: NSViewRepresentable {
    let link: ScrollLink
    let pane: ScrollSynchronization.Pane
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> LinkedScrollView {
        let scroll = HostedScrollView(content: content())
        link.attach(scroll, pane: pane)
        return scroll
    }

    func updateNSView(_ scroll: LinkedScrollView, context: Context) {
        guard let scroll = scroll as? HostedScrollView<Content> else { return }
        scroll.hosting.rootView = content()
        scroll.needsLayout = true
    }

    static func dismantleNSView(_ scroll: LinkedScrollView, coordinator: ()) { scroll.link?.detach(scroll) }
}

private final class HostedScrollView<Content: View>: LinkedScrollView {
    let hosting: NSHostingController<Content>
    private var measuring = false

    init(content: Content) {
        hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        super.init()
        documentView = hosting.view
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard !measuring, contentSize.width > 0 else { return }
        measuring = true
        defer { measuring = false }
        // Intrinsic height alone measures unwrapped text. Propose the actual viewport
        // width so the entire wrapped document is reachable, including its final line.
        let size = hosting.sizeThatFits(in: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        // Keep short documents at their natural height so SwiftUI does not center
        // the text vertically inside a viewport-sized hosting view.
        hosting.view.setFrameSize(NSSize(width: contentSize.width, height: ceil(size.height)))
        link?.geometryChanged(self)
    }
}

/// An explicit NSTextView keeps editing, selection, undo and IME support while exposing
/// its scroll view to the same link used by read-only text.
struct LinkedTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let link: ScrollLink
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LinkedScrollView {
        let scroll = LinkedScrollView()
        let editor = FocusReportingTextView(frame: .zero)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textColor = .textColor
        editor.font = .systemFont(ofSize: fontSize)
        editor.textContainerInset = .zero
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        editor.focusChanged = { [weak coordinator = context.coordinator] value in
            // First responder can change during a SwiftUI view update.
            Task { @MainActor in coordinator?.parent.focused = value }
        }
        scroll.documentView = editor
        link.attach(scroll, pane: .source)
        return scroll
    }

    func updateNSView(_ scroll: LinkedScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.undoManager?.removeAllActions()
            scroll.needsLayout = true
        }
        editor.font = .systemFont(ofSize: fontSize)
        if focused, let window = editor.window, window.firstResponder !== editor {
            window.makeFirstResponder(editor)
        }
    }

    static func dismantleNSView(_ scroll: LinkedScrollView, coordinator: Coordinator) {
        scroll.link?.detach(scroll)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LinkedTextEditor
        init(_ parent: LinkedTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class FocusReportingTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }
}

struct ScrollSyncButton: View {
    @Binding var enabled: Bool

    var body: some View {
        PaneIconButton(
            systemImage: "link", help: enabled ? "スクロール連動をオフ" : "スクロール連動をオン（分量に応じて位置を合わせます）",
            active: enabled
        ) { enabled.toggle() }
        .background(enabled ? Color.brand.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("スクロール連動")
        .accessibilityValue(enabled ? "オン" : "オフ")
        .accessibilityAddTraits(enabled ? [.isSelected] : [])
    }
}
