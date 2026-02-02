import SwiftUI
import AppKit

/// A view wrapper that enables click-through behavior on macOS.
/// When the window is not focused, clicks on this view will both
/// activate the window AND trigger the click action (no double-click needed).
struct ClickThroughView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> ClickThroughNSView<Content> {
        let view = ClickThroughNSView<Content>()
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    func updateNSView(_ nsView: ClickThroughNSView<Content>, context: Context) {
        if let hostingView = nsView.subviews.first as? NSHostingView<Content> {
            hostingView.rootView = content
        }
    }
}

/// Custom NSView that accepts the first mouse event, enabling click-through behavior.
class ClickThroughNSView<Content: View>: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - View Extension for convenience
extension View {
    /// Wraps this view to enable click-through behavior.
    /// When the window is inactive, clicks will both activate the window
    /// and trigger the click action simultaneously.
    func clickThrough() -> some View {
        ClickThroughView { self }
    }
}
