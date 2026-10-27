import AppKit
import ClaudeBarCore

/// Renders `UsageIcon` as a template image for the menu bar.
enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let scale = CGFloat(UsageIcon.size) / 18

    static func makeIcon(sessionUsed: Double?, weeklyUsed: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: self.outputSize)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: UsageIcon.size,
            pixelsHigh: UsageIcon.size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return image
        }

        rep.size = self.outputSize
        image.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return image
        }
        NSGraphicsContext.current = context
        for paint in UsageIcon.paints(sessionUsed: sessionUsed, weeklyUsed: weeklyUsed, stale: stale) {
            self.draw(paint, in: context.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()
        image.isTemplate = true
        return image
    }

    private static func draw(_ paint: UsageIcon.Paint, in cgContext: CGContext) {
        let color = NSColor.labelColor
        switch paint {
        case .fill(let rect, let opacity, let clip):
            cgContext.saveGState()
            if let clip {
                self.path(clip).addClip()
            }
            color.withAlphaComponent(opacity).setFill()
            NSBezierPath(rect: self.points(rect)).fill()
            cgContext.restoreGState()
        case .fillShape(let shape, let opacity):
            color.withAlphaComponent(opacity).setFill()
            self.path(shape).fill()
        case .stroke(let shape, let lineWidth, let opacity):
            let path = self.path(shape)
            path.lineWidth = lineWidth / self.scale
            color.withAlphaComponent(opacity).setStroke()
            path.stroke()
        case .clear(let rect):
            cgContext.saveGState()
            cgContext.setShouldAntialias(false)
            cgContext.clear(self.points(rect))
            cgContext.restoreGState()
        }
    }

    private static func points(_ rect: UsageIcon.Rect) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) / self.scale, y: CGFloat(rect.y) / self.scale,
            width: CGFloat(rect.width) / self.scale, height: CGFloat(rect.height) / self.scale)
    }

    private static func path(_ shape: UsageIcon.Shape) -> NSBezierPath {
        let radius = shape.cornerRadius / self.scale
        return NSBezierPath(roundedRect: self.points(shape.rect), xRadius: radius, yRadius: radius)
    }
}
