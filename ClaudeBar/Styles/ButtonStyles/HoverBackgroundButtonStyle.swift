import SwiftUI

/// A borderless button that fills a rounded chip behind its label on hover.
struct HoverBackgroundButtonStyle: ButtonStyle {
    /// Horizontal room the chip adds around a text label. A button that should sit
    /// flush with an edge pulls itself back by this much.
    static let textInset: CGFloat = 6
    /// The same for a bare glyph, which needs less breathing room than a word.
    static let iconInset: CGFloat = 4

    var padding = EdgeInsets(top: 3, leading: Self.textInset, bottom: 3, trailing: Self.textInset)
    var cornerRadius: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, padding: self.padding, cornerRadius: self.cornerRadius)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let padding: EdgeInsets
        let cornerRadius: CGFloat

        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
            return self.configuration.label
                .padding(self.padding)
                .background(shape.fill(Color.primary.opacity(self.fillOpacity)))
                .contentShape(shape)
                .onHover { self.isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: self.isHovering)
        }

        private var fillOpacity: Double {
            guard self.isEnabled else { return 0 }
            if self.configuration.isPressed { return 0.18 }
            return self.isHovering ? 0.10 : 0
        }
    }
}

extension ButtonStyle where Self == HoverBackgroundButtonStyle {
    /// Text buttons.
    static var hoverBackground: HoverBackgroundButtonStyle { HoverBackgroundButtonStyle() }

    /// Icon buttons: a tighter chip.
    static var hoverBackgroundIcon: HoverBackgroundButtonStyle {
        HoverBackgroundButtonStyle(
            padding: EdgeInsets(
                top: 3, leading: Self.iconInset, bottom: 3, trailing: Self.iconInset),
            cornerRadius: 4)
    }
}
