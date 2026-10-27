import CAppIndicator

/// Shows `MenuEntry` values as a GTK menu. Changes that keep the menu's shape
/// relabel its items in place, so a menu open under the pointer stays open.
@MainActor
final class MenuView {
    let root: Widget = gtk_menu_new()
    private var entries: [MenuEntry] = []
    private var nodes: [Node] = []
    /// What choosing an item does.
    var perform: @MainActor (TrayAction) -> Void = { _ in }

    private struct Node {
        let widget: Widget
        let children: [Node]
    }

    func show(_ entries: [MenuEntry]) {
        if entries.count == self.entries.count,
           zip(entries, self.entries).allSatisfy({ $0.hasSameShape(as: $1) })
        {
            self.relabel(self.nodes, from: self.entries, to: entries)
        } else {
            for node in self.nodes {
                gtk_widget_destroy(node.widget)
            }
            self.nodes = entries.map { self.build($0, into: self.root) }
            gtk_widget_show_all(self.root)
        }
        self.entries = entries
    }

    private func build(_ entry: MenuEntry, into menu: Widget) -> Node {
        let widget: Widget
        var children: [Node] = []
        switch entry.kind {
        case .separator:
            widget = gtk_separator_menu_item_new()
        case .item:
            widget = gtk_menu_item_new_with_label(entry.label)
        case .check(let isOn):
            widget = gtk_check_menu_item_new_with_label(entry.label)
            // Before connecting: setting the state emits "activate" too.
            gtk_check_menu_item_set_active(gtkCast(widget), isOn ? 1 : 0)
        case .submenu(let entries):
            widget = gtk_menu_item_new_with_label(entry.label)
            let submenu = gtk_menu_new()!
            children = entries.map { self.build($0, into: submenu) }
            gtk_menu_item_set_submenu(gtkCast(widget), submenu)
        }
        if let action = entry.action {
            onActivate(widget) { [unowned self] in self.perform(action) }
        } else if case .item = entry.kind {
            // A line of information rather than a command.
            gtk_widget_set_sensitive(widget, 0)
        }
        gtk_menu_shell_append(gtkCast(menu), widget)
        return Node(widget: widget, children: children)
    }

    private func relabel(_ nodes: [Node], from old: [MenuEntry], to new: [MenuEntry]) {
        for (node, (before, after)) in zip(nodes, zip(old, new)) {
            if after.label != before.label, after.kind != .separator {
                gtk_menu_item_set_label(gtkCast(node.widget), after.label)
            }
            if case .submenu(let oldChildren) = before.kind, case .submenu(let newChildren) = after.kind {
                self.relabel(node.children, from: oldChildren, to: newChildren)
            }
        }
    }
}
