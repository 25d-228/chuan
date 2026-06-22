import AppKit

// A warm, retro-pixel design system: cream paper, ink borders, a pink accent,
// hard square corners, monospaced uppercase labels, and crisp offset shadows.

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Palette {
    static let paper = NSColor(hex: 0xFAF3EA)
    static let cream = NSColor(hex: 0xF5E6D8)
    static let creamDeep = NSColor(hex: 0xE8D5C2)
    static let ink = NSColor(hex: 0x1A1A1A)
    static let pink = NSColor(hex: 0xF5A5B8)
    static let muted = NSColor(hex: 0x6B5E51)
    static let destructive = NSColor(hex: 0xC84B3C)
}

enum Typeface {
    static func display(_ size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Uppercase, letter-spaced, monospaced label — the "display" voice of the UI.
func makeDisplayLabel(_ text: String,
                      size: CGFloat = 11,
                      weight: NSFont.Weight = .bold,
                      color: NSColor = Palette.ink,
                      tracking: CGFloat = 1.5) -> NSTextField {
    let attributed = NSAttributedString(string: text.uppercased(), attributes: [
        .font: Typeface.display(size, weight: weight),
        .foregroundColor: color,
        .kern: tracking
    ])
    let label = NSTextField(labelWithAttributedString: attributed)
    label.lineBreakMode = .byTruncatingTail
    return label
}

/// The app's own icon, for in-window chrome. Falls back gracefully.
func appIconImage() -> NSImage? {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let image = NSImage(contentsOf: url) {
        return image
    }
    let appIcon = NSApp.applicationIconImage
    if let appIcon, appIcon.isValid { return appIcon }
    return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
}

/// Paper background with a faint dot grid.
final class PaperBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.paper.setFill()
        dirtyRect.fill()

        Palette.ink.withAlphaComponent(0.06).setFill()
        let spacing: CGFloat = 18
        let radius: CGFloat = 1
        var y: CGFloat = 0
        while y < bounds.height {
            var x: CGFloat = 0
            while x < bounds.width {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: radius * 2, height: radius * 2)).fill()
                x += spacing
            }
            y += spacing
        }
    }
}

/// A tactile button: square, 2px ink border, crisp offset shadow, uppercase
/// monospaced title. Hover → pink, press → inverted with the shadow collapsing.
final class PixelButton: NSControl {
    enum Kind { case normal, destructive }

    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var kind: Kind = .normal { didSet { needsDisplay = true } }

    private var hovering = false
    private var pressed = false
    private let shadowOffset: CGFloat = 4
    private let hInset: CGFloat = 14
    private let vInset: CGFloat = 7

    init(title: String, target: AnyObject?, action: Selector?, kind: Kind = .normal) {
        self.title = title
        self.kind = kind
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func titleString(inverted: Bool) -> NSAttributedString {
        let color = inverted ? Palette.cream : Palette.ink
        return NSAttributedString(string: title.uppercased(), attributes: [
            .font: Typeface.display(11, weight: .bold),
            .foregroundColor: color,
            .kern: 1.2
        ])
    }

    override var intrinsicContentSize: NSSize {
        let size = titleString(inverted: false).size()
        return NSSize(width: ceil(size.width) + hInset * 2 + shadowOffset,
                      height: ceil(size.height) + vInset * 2 + shadowOffset)
    }

    override func draw(_ dirtyRect: NSRect) {
        let faceSize = NSSize(width: bounds.width - shadowOffset, height: bounds.height - shadowOffset)
        let faceOrigin = pressed ? NSPoint(x: shadowOffset, y: shadowOffset) : .zero
        let shadowOrigin = pressed ? NSPoint.zero : NSPoint(x: shadowOffset, y: shadowOffset)

        Palette.ink.setFill()
        NSBezierPath(rect: NSRect(origin: shadowOrigin, size: faceSize)).fill()

        let faceRect = NSRect(origin: faceOrigin, size: faceSize)
        let accent = kind == .destructive ? Palette.destructive : Palette.pink
        let fillColor: NSColor = pressed ? Palette.ink : (hovering ? accent : Palette.cream)
        let inner = faceRect.insetBy(dx: 1, dy: 1)
        fillColor.setFill()
        NSBezierPath(rect: inner).fill()
        Palette.ink.setStroke()
        let border = NSBezierPath(rect: inner)
        border.lineWidth = 2
        border.stroke()

        let text = titleString(inverted: pressed)
        let textSize = text.size()
        text.draw(at: NSPoint(x: faceRect.midX - textSize.width / 2,
                              y: faceRect.midY - textSize.height / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        let wasInside = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if wasInside, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}

/// A list row: cream fill, 2px ink border, square corners, pink hover.
final class SourceRowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.cream.cgColor
        layer?.borderColor = Palette.ink.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Palette.pink.withAlphaComponent(0.30).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = Palette.cream.cgColor
    }
}

/// Three decorative "traffic light" squares for the window header.
func makeTrafficLights() -> NSView {
    func square(_ color: NSColor, bordered: Bool = false) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        if bordered {
            view.layer?.borderColor = Palette.ink.cgColor
            view.layer?.borderWidth = 1
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 11),
            view.heightAnchor.constraint(equalToConstant: 11)
        ])
        return view
    }
    let stack = NSStackView(views: [
        square(Palette.destructive),
        square(Palette.cream, bordered: true),
        square(Palette.ink)
    ])
    stack.orientation = .horizontal
    stack.spacing = 6
    return stack
}
