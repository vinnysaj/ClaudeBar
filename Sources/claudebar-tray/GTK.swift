import CAppIndicator
import Foundation

// GTK runs on the main thread inside gtk_main, which never drains the queue
// Swift's main actor runs on, so nothing here may `await` the main actor:
// work reaches the main thread through GLib, and code already there asserts it.

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// GObject's subclassing as Swift sees it: the same pointer, read as a parent
/// or child type.
func gtkCast<Source, Target>(_ pointer: UnsafeMutablePointer<Source>) -> UnsafeMutablePointer<Target> {
    UnsafeMutablePointer<Target>(OpaquePointer(pointer))
}

private final class MainThreadWork: Sendable {
    let run: @Sendable @MainActor () -> Void

    init(_ run: @escaping @Sendable @MainActor () -> Void) {
        self.run = run
    }
}

/// Runs `work` on the GTK main loop, from any thread.
func onMainLoop(_ work: @escaping @Sendable @MainActor () -> Void) {
    let box = Unmanaged.passRetained(MainThreadWork(work)).toOpaque()
    g_idle_add({ pointer in
        let work = Unmanaged<MainThreadWork>.fromOpaque(pointer!).takeRetainedValue()
        MainActor.assumeIsolated { work.run() }
        return 0  // G_SOURCE_REMOVE: once only.
    }, box)
}

private final class SignalHandler {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }
}

/// Calls `action` when the menu item is chosen.
@MainActor
func onActivate(_ item: Widget, _ action: @escaping @MainActor () -> Void) {
    let handler = Unmanaged.passRetained(SignalHandler(action)).toOpaque()
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
        let handler = Unmanaged<SignalHandler>.fromOpaque(data!).takeUnretainedValue()
        MainActor.assumeIsolated { handler.action() }
    }
    let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
        Unmanaged<SignalHandler>.fromOpaque(data!).release()
    }
    g_signal_connect_data(item, "activate", unsafeBitCast(callback, to: GCallback.self), handler, release, GConnectFlags(0))
}

@MainActor
enum Dialog {
    /// Asks before something that can't be undone; true to go ahead.
    static func confirm(_ message: String, detail: String, action: String) -> Bool {
        self.run(message, detail: detail, buttons: [("_Cancel", GTK_RESPONSE_CANCEL), (action, GTK_RESPONSE_ACCEPT)])
            == GTK_RESPONSE_ACCEPT.rawValue
    }

    static func show(_ message: String) {
        _ = self.run(message, detail: nil, buttons: [("_OK", GTK_RESPONSE_OK)])
    }

    private static func run(_ message: String, detail: String?, buttons: [(String, GtkResponseType)]) -> Int32 {
        let dialog = gtk_dialog_new()!
        gtk_window_set_title(gtkCast(dialog), "ClaudeBar")
        gtk_window_set_keep_above(gtkCast(dialog), 1)
        for (label, response) in buttons {
            gtk_dialog_add_button(gtkCast(dialog), label, response.rawValue)
        }
        let content = gtk_dialog_get_content_area(gtkCast(dialog))!
        gtk_container_set_border_width(gtkCast(content), 12)
        gtk_box_set_spacing(gtkCast(content), 8)
        for (text, isTitle) in [(message, true), (detail, false)] {
            guard let text else { continue }
            let label = gtk_label_new(nil)!
            if isTitle {
                gtk_label_set_markup(gtkCast(label), "<b>\(Self.escape(text))</b>")
            } else {
                gtk_label_set_text(gtkCast(label), text)
            }
            gtk_label_set_line_wrap(gtkCast(label), 1)
            gtk_label_set_max_width_chars(gtkCast(label), 50)
            gtk_label_set_xalign(gtkCast(label), 0)
            gtk_container_add(gtkCast(content), label)
        }
        gtk_widget_show_all(dialog)
        let response = gtk_dialog_run(gtkCast(dialog))
        gtk_widget_destroy(dialog)
        return response
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

@MainActor
enum Clipboard {
    private static var clipboard: OpaquePointer {
        gtk_clipboard_get(gdk_atom_intern("CLIPBOARD", 0))
    }

    static func copy(_ text: String) {
        gtk_clipboard_set_text(self.clipboard, text, -1)
    }

    static func text() -> String? {
        guard let text = gtk_clipboard_wait_for_text(self.clipboard) else { return nil }
        defer { g_free(text) }
        return String(cString: text)
    }
}

/// Opens a page in the default browser; false when none could.
@MainActor
func openInBrowser(_ url: URL) -> Bool {
    g_app_info_launch_default_for_uri(url.absoluteString, nil, nil) != 0
}
