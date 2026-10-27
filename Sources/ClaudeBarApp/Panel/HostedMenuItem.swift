import AppKit
import SwiftUI

/// Menu items that host SwiftUI and keep their height in step with it, so
/// content can grow and shrink while the menu is open. An open menu relays
/// itself out when an item view's frame changes, but nothing changes that
/// frame on its own: the hosting view's fitting size moves while its frame
/// stays put, clipping new content.
@MainActor
enum HostedMenuItem {
    static func make<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> NSMenuItem {
        let resizer = MenuItemResizer()
        let hostingView = NSHostingView(
            rootView: content()
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resizer.resize(toHeight: $0) })
        resizer.view = hostingView
        hostingView.frame.size = NSSize(width: width, height: hostingView.fittingSize.height)

        let item = NSMenuItem()
        item.view = hostingView
        return item
    }

    /// A submenu whose only item is `content`: the panel that opens when the
    /// parent row is hovered.
    static func submenu<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(self.make(width: width, content: content))
        return menu
    }
}

@MainActor
private final class MenuItemResizer {
    weak var view: NSView?

    func resize(toHeight height: CGFloat) {
        guard let view, abs(view.frame.height - height) >= 0.5 else { return }
        view.setFrameSize(NSSize(width: view.frame.width, height: height))
    }
}
