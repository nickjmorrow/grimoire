import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public extension OutlineAttr {
    /// Set on paragraphs that have child blocks (drives the collapse ring and click-to-collapse).
    static let hasChildren = NSAttributedString.Key("grim.hasChildren")
}

/// Visual constants the layout fragments need (set from the theme).
public struct OutlineMetrics {
    public var indent: CGFloat = 22
    public var gutter: CGFloat = 20
    public var bulletRadius: CGFloat = 3
    public var bullet: PlatformColor = .gray
    public var accent: PlatformColor = .yellow
    public var success: PlatformColor = .green
    public var danger: PlatformColor = .red
    public var textFaint: PlatformColor = .gray
    public var fontSize: CGFloat = 15
    public var lineHeightMultiple: CGFloat = 1.35
    public var linePadding: CGFloat = 5          // NSTextContainer.lineFragmentPadding
    public init() {}
    public init(theme: Theme) {
        indent = CGFloat(theme.spacing.indent)
        gutter = 20
        bullet = theme.colors.platformColor(\.bullet)
        accent = theme.colors.platformColor(\.accent)
        success = theme.colors.platformColor(\.success)
        danger = theme.colors.platformColor(\.danger)
        textFaint = theme.colors.platformColor(\.textFaint)
        fontSize = CGFloat(theme.fonts.bodySize)
        lineHeightMultiple = CGFloat(theme.fonts.lineHeightMultiple)
    }
}

/// Draws the bullet, task checkbox or collapse ring in the left gutter of a block paragraph.
final class OutlineLayoutFragment: NSTextLayoutFragment {
    var metrics = OutlineMetrics()
    var depth = 0
    var collapsed = false
    var hasChildren = false
    var task: TaskState?
    var diagram: PlatformImage?
    var diagramError: String?

    /// Drawing is relative to where the text starts, so the gutter lies at negative x; widen the surface to include it.
    override var renderingSurfaceBounds: CGRect {
        let left = metrics.gutter + metrics.linePadding + 6
        return super.renderingSurfaceBounds.union(CGRect(x: -left, y: 0, width: left, height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        drawDiagram(at: point, in: context)
        guard let line = textLineFragments.first else { return }
        let b = line.typographicBounds
        // Centre the marker in the gutter just left of where the text actually starts (robust to indents and padding).
        let cx = point.x + b.origin.x - metrics.linePadding - metrics.gutter / 2
        // Centre on the x-height of the first line rather than the whole line box (which includes the line-height padding).
        let cy = point.y + b.origin.y + line.glyphOrigin.y - metrics.fontSize * 0.34
        let r = metrics.bulletRadius
        context.saveGState()
        defer { context.restoreGState() }
        if let task {
            let side: CGFloat = 13
            let box = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            let path = CGPath(roundedRect: box, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            switch task {
            case .done:
                context.setFillColor(metrics.success.cgColor); context.addPath(path); context.fillPath()
                context.setStrokeColor(PlatformColor.black.withAlphaComponent(0.75).cgColor)
                context.setLineWidth(1.8); context.setLineCap(.round); context.setLineJoin(.round)
                context.move(to: CGPoint(x: box.minX + 3, y: box.midY)); context.addLine(to: CGPoint(x: box.minX + 5.5, y: box.midY + 2.6))
                context.addLine(to: CGPoint(x: box.maxX - 3, y: box.midY - 2.6)); context.strokePath()
            case .doing:
                context.setStrokeColor(metrics.accent.cgColor); context.setLineWidth(1.6); context.addPath(path); context.strokePath()
                context.setFillColor(metrics.accent.cgColor)
                context.fill(CGRect(x: box.minX + 3.5, y: box.minY + 3.5, width: side / 2 - 0.5, height: side - 7))
            case .todo:
                context.setStrokeColor(metrics.accent.cgColor); context.setLineWidth(1.6); context.addPath(path); context.strokePath()
            }
            return
        }
        if collapsed && hasChildren {
            // a ring with a soft halo says "there is more in here"
            context.setFillColor(metrics.bullet.withAlphaComponent(0.28).cgColor)
            context.fillEllipse(in: CGRect(x: cx - r - 3.5, y: cy - r - 3.5, width: (r + 3.5) * 2, height: (r + 3.5) * 2))
        }
        context.setFillColor(metrics.bullet.cgColor)
        context.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }
}

extension OutlineLayoutFragment {
    static let maxDiagramWidth: CGFloat = 680

    /// Size a diagram image is drawn at (shrunk to fit, never enlarged).
    static func diagramSize(_ image: PlatformImage) -> CGSize {
        let w = min(image.size.width, maxDiagramWidth)
        return CGSize(width: w, height: image.size.height * (w / max(1, image.size.width)))
    }

    fileprivate func drawDiagram(at point: CGPoint, in context: CGContext) {
        guard diagram != nil || diagramError != nil, let first = textLineFragments.first, let last = textLineFragments.last else { return }
        let x = point.x + first.typographicBounds.origin.x
        let y = point.y + last.typographicBounds.maxY + 8
        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let image = diagram {
            let size = Self.diagramSize(image)
            image.draw(in: NSRect(x: x, y: y, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let message = diagramError {
            NSAttributedString(string: "Diagram error: " + message, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: metrics.danger]).draw(at: NSPoint(x: x, y: y))
        }
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        if let image = diagram {
            let size = Self.diagramSize(image)
            image.draw(in: CGRect(x: x, y: y, width: size.width, height: size.height))
        } else if let message = diagramError {
            NSAttributedString(string: "Diagram error: " + message, attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: metrics.danger]).draw(at: CGPoint(x: x, y: y))
        }
        #endif
    }
}

/// Hides collapsed descendants and builds the layout fragments.
public final class OutlineTextDelegate: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    public var metrics = OutlineMetrics()

    public func textContentManager(_ manager: NSTextContentManager, shouldEnumerate element: NSTextElement, options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        guard let p = element as? NSTextParagraph, p.attributedString.length > 0 else { return true }
        return p.attributedString.attribute(OutlineAttr.hidden, at: 0, effectiveRange: nil) == nil
    }

    public func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
        let f = OutlineLayoutFragment(textElement: element, range: element.elementRange)
        f.metrics = metrics
        if let p = element as? NSTextParagraph, p.attributedString.length > 0 {
            let a = p.attributedString
            f.depth = a.attribute(OutlineAttr.depth, at: 0, effectiveRange: nil) as? Int ?? 0
            f.collapsed = a.attribute(OutlineAttr.collapsed, at: 0, effectiveRange: nil) as? Bool ?? false
            f.hasChildren = a.attribute(OutlineAttr.hasChildren, at: 0, effectiveRange: nil) as? Bool ?? false
            f.diagram = a.attribute(OutlineAttr.diagram, at: 0, effectiveRange: nil) as? PlatformImage
            f.diagramError = a.attribute(OutlineAttr.diagramError, at: 0, effectiveRange: nil) as? String
            let text = a.string
            f.task = text.hasPrefix("TODO ") ? .todo : text.hasPrefix("DOING ") ? .doing : text.hasPrefix("DONE ") ? .done : nil
        }
        return f
    }
}
