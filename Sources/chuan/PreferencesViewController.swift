import AppKit
import KeyboardShortcuts

/// A stack view whose contents flow from the top down (needed inside a scroll view).
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class PreferencesViewController: NSViewController {
    private let rowsStack = FlippedStackView()
    private var displayedIDs: [String] = []

    override func loadView() {
        view = PaperBackgroundView(frame: NSRect(x: 0, y: 0, width: 520, height: 540))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        reloadSources(force: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func buildUI() {
        let header = makeHeader()
        view.addSubview(header)

        let caption = makeDisplayLabel("Press a shortcut to switch to that input source",
                                       size: 10, weight: .medium, color: Palette.muted, tracking: 0.6)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.creamDeep
        scrollView.documentView = rowsStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])

        let addButton = PixelButton(title: "+ Add input source…", target: self, action: #selector(addInputSource))
        let refreshButton = PixelButton(title: "Refresh", target: self, action: #selector(refresh))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let quitButton = PixelButton(title: "Quit", target: self, action: #selector(quit), kind: .destructive)

        let buttonBar = NSStackView(views: [addButton, refreshButton, spacer, quitButton])
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 10

        let content = NSStackView(views: [caption, scrollView, buttonBar])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),

            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
    }

    private func makeHeader() -> NSView {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = Palette.cream.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let bottomBorder = NSView()
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = Palette.ink.cgColor
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(bottomBorder)

        let icon = NSImageView()
        icon.image = appIconImage()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = makeDisplayLabel("chuan", size: 15, weight: .bold, tracking: 3)
        title.translatesAutoresizingMaskIntoConstraints = false

        let lights = makeTrafficLights()
        lights.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(icon)
        header.addSubview(title)
        header.addSubview(lights)

        NSLayoutConstraint.activate([
            bottomBorder.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 2),

            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            lights.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            lights.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    private func makeRow(for source: InputSource) -> NSView {
        let row = SourceRowView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = source.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = makeDisplayLabel(source.name, size: 11, weight: .medium, tracking: 0.6)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let recorder = KeyboardShortcuts.RecorderCocoa(for: source.shortcutName) { shortcut in
            InputSourceSelector.shared.updateShortcutSignature(
                shortcut.map {
                    ShortcutSignature(
                        keyCode: $0.carbonKeyCode,
                        carbonModifiers: $0.carbonModifiers
                    )
                },
                for: source.id
            )
        }
        recorder.bezelStyle = .squareBezel
        recorder.focusRingType = .none
        recorder.font = Typeface.display(11, weight: .regular)
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let stack = NSStackView(views: [icon, label, recorder])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            recorder.widthAnchor.constraint(equalToConstant: 140),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9)
        ])
        return row
    }

    // MARK: - Data

    /// Rebuild the list if the set of input sources changed, and make sure each
    /// has a registered global handler.
    private func reloadSources(force: Bool) {
        let sources = InputSource.all
        let ids = sources.map(\.id)
        guard force || ids != displayedIDs else { return }
        displayedIDs = ids

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for source in sources {
            let row = makeRow(for: source)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -20).isActive = true
        }
        ShortcutRegistry.shared.sync()
    }

    // MARK: - Actions

    @objc private func appBecameActive() {
        reloadSources(force: false)
    }

    @objc private func addInputSource() {
        // Adding a brand-new language/input source is done in System Settings.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refresh() {
        reloadSources(force: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
