import AppKit
import ScreenCoachCore

/// The "what are you looking for" input.
///
/// Unlike the overlay, this panel *does* take keys — you are typing into it —
/// so it is a normal panel that can become key. What it must not do is
/// activate the app underneath it or change which app is frontmost, because
/// the whole query is about the app the user was just in. `becomesKeyOnlyIfNeeded`
/// plus an accessory-policy app is what buys that.
public final class CommandBar: NSPanel, NSTextFieldDelegate {

    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "")
    private var suggestionRows: [NSTextField] = []
    private let stack = NSStackView()

    /// Fires as the user types, so candidates can be previewed live.
    public var onQueryChanged: ((String) -> Void)?
    /// Fires on Return.
    public var onSubmit: ((String) -> Void)?
    public var onCancel: (() -> Void)?

    public init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 560, height: 58),
                   styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        field.placeholderString = "Name a control — “the Preferences button”"
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [field, hint, stack])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(root)
        contentView = container
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            field.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
        ])
    }

    public override var canBecomeKey: Bool { true }

    // MARK: - Presentation

    public func present(status: String) {
        hint.stringValue = status
        showSuggestions([])
        field.stringValue = ""
        positionOnActiveScreen()
        orderFrontRegardless()
        makeKey()
        field.becomeFirstResponder()
    }

    public func dismiss() {
        orderOut(nil)
    }

    private func positionOnActiveScreen() {
        // The screen with the mouse, not `NSScreen.main`: the user's
        // attention is where their cursor is, and main only tracks focus.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let size = frame.size
        setFrameOrigin(CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + screen.frame.height * 0.62
        ))
    }

    /// Live candidate preview. Seeing the resolver's shortlist while typing is
    /// how you learn what phrasing it understands, which matters more here
    /// than in a normal search box because the vocabulary is the app's, not
    /// ours.
    public func showSuggestions(_ rows: [String]) {
        for v in suggestionRows { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        suggestionRows = rows.prefix(3).map { text in
            let l = NSTextField(labelWithString: text)
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .tertiaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            return l
        }
        for l in suggestionRows { stack.addArrangedSubview(l) }
        let extra = CGFloat(suggestionRows.count) * 17
        setContentSize(NSSize(width: 560, height: 58 + extra))
    }

    public func setStatus(_ text: String) { hint.stringValue = text }

    /// Push a transcript in from voice. Same field as typing, so everything
    /// downstream sees one input path.
    public func setQuery(_ text: String) {
        field.stringValue = text
    }

    public var query: String {
        field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Input

    public func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let q = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty { onSubmit?(q) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
