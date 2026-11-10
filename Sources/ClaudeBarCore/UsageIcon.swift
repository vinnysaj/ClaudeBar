import Foundation

/// The menu bar icon: the first two limit windows the active account reports,
/// each a bar filled to its usage. The top bar is drawn as a crab with arms,
/// legs and eyes. That's session over weekly, or for an account without a
/// session limit, weekly over Fable. Laid out as paint operations on a 36-pixel
/// square with y running up, which the Mac renders with AppKit and the Linux
/// tray as SVG.
public enum UsageIcon {
    public static let size = 36

    public struct Rect: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    /// A rounded rectangle; `cornerRadius` in pixels.
    public struct Shape: Sendable, Equatable {
        public let rect: Rect
        public let cornerRadius: Double
    }

    public enum Paint: Sendable, Equatable {
        /// Fills `rect`, inside `clip` when given.
        case fill(Rect, opacity: Double, clip: Shape?)
        case fillShape(Shape, opacity: Double)
        /// Strokes the shape's outline, the line centered on it.
        case stroke(Shape, lineWidth: Double, opacity: Double)
        /// Makes everything painted so far under `rect` transparent.
        case clear(Rect)
    }

    /// Nil usage, or a second window the account doesn't have, draws an empty
    /// bar; `stale` dims everything.
    public static func paints(usage: AccountUsage?, stale: Bool, now: Date) -> [Paint] {
        let windows = usage?.limitWindows.map { Double($0.effectiveUsedPercent(at: now)) } ?? []
        let topUsed = windows.first
        let bottomUsed = windows.dropFirst().first
        let trackFillOpacity = stale ? 0.18 : 0.28
        let trackStrokeOpacity = stale ? 0.28 : 0.44
        let fillOpacity = stale ? 0.55 : 1.0
        let barWidth = 30
        let barX = (self.size - barWidth) / 2

        let top = self.bar(
            Rect(x: barX, y: 19, width: barWidth, height: 12), cornerRadius: 0, fillPercent: topUsed,
            fillOpacity: fillOpacity, trackFillOpacity: trackFillOpacity, trackStrokeOpacity: trackStrokeOpacity)
        let bottomOpacity = bottomUsed != nil ? 1.0 : 0.45
        let bottom = self.bar(
            Rect(x: barX, y: 5, width: barWidth, height: 8), cornerRadius: 4, fillPercent: bottomUsed,
            fillOpacity: fillOpacity, trackFillOpacity: trackFillOpacity * bottomOpacity,
            trackStrokeOpacity: trackStrokeOpacity * bottomOpacity)
        return top + self.crab(around: Rect(x: barX, y: 19, width: barWidth, height: 12), opacity: fillOpacity)
            + bottom
    }

    private static func bar(
        _ rect: Rect, cornerRadius: Double, fillPercent: Double?, fillOpacity: Double,
        trackFillOpacity: Double, trackStrokeOpacity: Double) -> [Paint]
    {
        let track = Shape(rect: rect, cornerRadius: cornerRadius)
        let inset = 1
        let outline = Shape(
            rect: Rect(
                x: rect.x + inset, y: rect.y + inset,
                width: max(0, rect.width - inset * 2), height: max(0, rect.height - inset * 2)),
            cornerRadius: max(0, cornerRadius - Double(inset)))
        var paints: [Paint] = [
            .fillShape(track, opacity: trackFillOpacity),
            .stroke(outline, lineWidth: 2, opacity: trackStrokeOpacity),
        ]
        if let fillPercent {
            let clamped = max(0, min(fillPercent / 100, 1))
            let fillWidth = max(0, min(rect.width, Int((Double(rect.width) * clamped).rounded())))
            if fillWidth > 0 {
                paints.append(.fill(
                    Rect(x: rect.x, y: rect.y, width: fillWidth, height: rect.height), opacity: fillOpacity,
                    clip: track))
            }
        }
        return paints
    }

    private static func crab(around bar: Rect, opacity: Double) -> [Paint] {
        let armSize = 3
        let armY = bar.y + 3
        var paints: [Paint] = [
            .fill(Rect(x: bar.x - armSize, y: armY, width: armSize, height: armSize), opacity: opacity, clip: nil),
            .fill(Rect(x: bar.x + bar.width, y: armY, width: armSize, height: armSize), opacity: opacity, clip: nil),
        ]

        let legWidth = 2
        let legHeight = 3
        let legY = bar.y - legHeight
        let midX = bar.x + bar.width / 2
        let innerGap = 4
        let outerGap = 5
        let legPositions = [
            midX - innerGap - legWidth,
            midX - innerGap - legWidth - outerGap,
            midX + innerGap,
            midX + innerGap + outerGap,
        ]
        for legX in legPositions {
            paints.append(.fill(Rect(x: legX, y: legY, width: legWidth, height: legHeight), opacity: opacity, clip: nil))
        }

        let eyeWidth = 2
        let eyeHeight = 5
        let eyeOffset = 6
        let eyeY = bar.y + (bar.height - eyeHeight) / 2
        paints.append(.clear(Rect(x: midX - eyeOffset - eyeWidth / 2, y: eyeY, width: eyeWidth, height: eyeHeight)))
        paints.append(.clear(Rect(x: midX + eyeOffset - eyeWidth / 2, y: eyeY, width: eyeWidth, height: eyeHeight)))
        return paints
    }

    // MARK: - SVG

    /// The icon as an SVG document in `color` (CSS), for the Linux tray.
    public static func svg(_ paints: [Paint], color: String) -> String {
        var definitions: [String] = []
        var body = ""
        for (index, paint) in paints.enumerated() {
            switch paint {
            case .fill(let rect, let opacity, let clip):
                var clipAttribute = ""
                if let clip {
                    definitions.append("<clipPath id=\"c\(index)\">\(self.svgRect(clip.rect, radius: clip.cornerRadius))</clipPath>")
                    clipAttribute = " clip-path=\"url(#c\(index))\""
                }
                body += self.svgRect(rect, radius: 0, attributes: "fill=\"\(color)\" fill-opacity=\"\(opacity)\"\(clipAttribute)")
            case .fillShape(let shape, let opacity):
                body += self.svgRect(shape.rect, radius: shape.cornerRadius, attributes: "fill=\"\(color)\" fill-opacity=\"\(opacity)\"")
            case .stroke(let shape, let lineWidth, let opacity):
                body += self.svgRect(
                    shape.rect, radius: shape.cornerRadius,
                    attributes: "fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(lineWidth)\" stroke-opacity=\"\(opacity)\"")
            case .clear(let rect):
                // Only what's painted so far goes under the mask, as a clear erases.
                definitions.append(
                    "<mask id=\"m\(index)\" maskUnits=\"userSpaceOnUse\"><rect width=\"\(self.size)\" height=\"\(self.size)\" fill=\"white\"/>"
                        + self.svgRect(rect, radius: 0, attributes: "fill=\"black\"") + "</mask>")
                body = "<g mask=\"url(#m\(index))\">\(body)</g>"
            }
        }
        return """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(self.size)" height="\(self.size)" viewBox="0 0 \(self.size) \(self.size)">\
            <defs>\(definitions.joined())</defs>\(body)</svg>
            """
    }

    /// SVG's y runs down, so rects flip about the middle.
    private static func svgRect(_ rect: Rect, radius: Double, attributes: String = "") -> String {
        let y = self.size - rect.y - rect.height
        let corner = radius > 0 ? " rx=\"\(radius)\"" : ""
        let extra = attributes.isEmpty ? "" : " \(attributes)"
        return "<rect x=\"\(rect.x)\" y=\"\(y)\" width=\"\(rect.width)\" height=\"\(rect.height)\"\(corner)\(extra)/>"
    }
}
