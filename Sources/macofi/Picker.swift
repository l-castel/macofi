import AppKit

/// Borderless windows can't become key by default, which would block typing.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Flipped container that draws the rounded background, border and input box.
final class RootView: NSView {
    var config = Config()
    var inputRect = NSRect.zero
    var separatorRect = NSRect.zero

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ config: Config) {
        self.config = config
        layer?.backgroundColor = config.background.cgColor
        layer?.borderColor = config.border.cgColor
        layer?.borderWidth = config.borderWidth
        layer?.cornerRadius = config.borderRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if config.inputBackground.alphaComponent > 0 {
            config.inputBackground.setFill()
            NSBezierPath(roundedRect: inputRect, xRadius: config.rowRadius, yRadius: config.rowRadius).fill()
        }
        if config.separatorWidth > 0 {
            config.separator.setFill()
            separatorRect.fill()
        }
    }
}

/// Draws the result rows itself, which keeps every pixel under config control.
final class ListView: NSView {
    /// Fonts are resolved once per config instead of on every redraw (mouse moves redraw).
    var config = Config() { didSet { font = config.font; boldFont = config.boldFont } }
    private var font = NSFont.systemFont(ofSize: 15)
    private var boldFont = NSFont.boldSystemFont(ofSize: 15)
    var matches: [Match] = [] { didSet { selected = 0; offset = 0; needsDisplay = true } }
    var selected = 0 { didSet { scrollToSelection(); needsDisplay = true } }
    var onActivate: ((Int) -> Void)?
    private var offset = 0
    private var scrollAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }

    private var rowStride: CGFloat { config.rowHeight + config.rowSpacing }

    func move(by delta: Int) {
        guard !matches.isEmpty else { return }
        selected = max(0, min(matches.count - 1, selected + delta))
    }

    private func scrollToSelection() {
        if selected < offset { offset = selected }
        if selected >= offset + config.lines { offset = selected - config.lines + 1 }
    }

    private func row(at point: NSPoint) -> Int? {
        let index = offset + Int(point.y / rowStride)
        return index < matches.count ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let end = min(matches.count, offset + config.lines)
        guard offset < end else { return }

        for index in offset..<end {
            let match = matches[index]
            let y = CGFloat(index - offset) * rowStride
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: config.rowHeight)
            let isSelected = index == selected

            if isSelected {
                config.selectionBackground.setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: config.rowRadius, yRadius: config.rowRadius).fill()
            }

            var x: CGFloat = 10
            if config.showIcons, let icon = match.item.icon {
                let size = config.iconSize
                icon.draw(in: NSRect(x: x, y: y + (config.rowHeight - size) / 2, width: size, height: size),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += size + 10
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSMutableAttributedString(string: match.item.title, attributes: [
                .font: font,
                .foregroundColor: isSelected ? config.selectionForeground : config.foreground,
                .paragraphStyle: paragraph,
            ])
            for range in match.ranges {
                if config.highlightMatches { text.addAttribute(.foregroundColor, value: config.match, range: range) }
                if config.boldMatches { text.addAttribute(.font, value: boldFont, range: range) }
            }
            let textRect = NSRect(x: x, y: y + (config.rowHeight - lineHeight) / 2,
                                  width: bounds.width - x - 10, height: lineHeight)
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)), index != selected { selected = index }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)) {
            selected = index
            onActivate?(index)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator -= event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? rowStride : 1)
        let steps = Int(scrollAccumulator)
        guard steps != 0 else { return }
        scrollAccumulator -= CGFloat(steps)
        let maxOffset = max(0, matches.count - config.lines)
        offset = max(0, min(maxOffset, offset + steps))
        selected = max(offset, min(offset + config.lines - 1, selected))
        needsDisplay = true
    }
}

/// Owns the window and wires keyboard input to the list.
final class Picker: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    enum Outcome { case chose(Item), typed(String), cancelled }

    private let panel: PickerPanel
    private let root = RootView()
    private let promptLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let list = ListView()

    private var config = Config()
    private var items: [Item] = []
    private var history: History?
    private var keepOrder = false
    private var finished = false
    var onFinish: ((Outcome) -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = PickerPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = root

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        list.onActivate = { [weak self] _ in self?.accept() }

        root.addSubview(promptLabel)
        root.addSubview(field)
        root.addSubview(list)
    }

    func show(config: Config, items: [Item], history: History?, keepOrder: Bool) {
        self.config = config
        self.items = items
        self.history = history
        self.keepOrder = keepOrder
        finished = false

        layout()
        field.stringValue = ""
        refilter()

        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = config.cursor
            editor.selectedTextAttributes = [.backgroundColor: config.selectionBackground,
                                             .foregroundColor: config.selectionForeground]
        }
        panel.invalidateShadow()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func layout() {
        let c = config
        let inputFont = c.inputFont
        let inputLine = ceil(inputFont.ascender - inputFont.descender + inputFont.leading)
        let inputHeight = inputLine + 16
        let gap: CGFloat = 8
        let listHeight = CGFloat(c.lines) * c.rowHeight + CGFloat(c.lines - 1) * c.rowSpacing
        let contentWidth = c.width - 2 * c.padding

        let inputRect = NSRect(x: c.padding, y: c.padding, width: contentWidth, height: inputHeight)
        var y = inputRect.maxY + gap
        let separatorRect = NSRect(x: c.padding, y: y, width: contentWidth, height: c.separatorWidth)
        if c.separatorWidth > 0 { y = separatorRect.maxY + gap }
        let listRect = NSRect(x: c.padding, y: y, width: contentWidth, height: listHeight)
        let height = listRect.maxY + c.padding

        // Center on the screen that has the mouse, like a tiling WM's focused monitor.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: round(screen.frame.midX - c.width / 2),
                           y: round(screen.frame.midY - height / 2 + c.verticalOffset),
                           width: c.width, height: height)
        panel.setFrame(frame, display: false)
        panel.hasShadow = c.shadow
        panel.alphaValue = c.opacity

        root.inputRect = inputRect
        root.separatorRect = separatorRect
        root.apply(c)

        // The prompt gets the field's exact frame height and y: both are NSTextFields with the
        // same font, so identical frames put their text on the same baseline.
        let fieldHeight = inputLine + 4
        let fieldY = inputRect.minY + (inputHeight - fieldHeight) / 2
        var textX = inputRect.minX + 10
        promptLabel.isHidden = c.prompt.isEmpty
        if !c.prompt.isEmpty {
            promptLabel.font = inputFont
            promptLabel.textColor = c.promptColor
            promptLabel.stringValue = c.prompt
            promptLabel.sizeToFit()
            promptLabel.frame = NSRect(x: textX, y: fieldY, width: promptLabel.frame.width, height: fieldHeight)
            textX = promptLabel.frame.maxX + 6
        }

        field.font = inputFont
        field.textColor = c.foreground
        field.placeholderAttributedString = NSAttributedString(string: c.placeholder, attributes: [
            .font: inputFont, .foregroundColor: c.placeholderColor,
        ])
        field.frame = NSRect(x: textX, y: fieldY, width: inputRect.maxX - textX - 10, height: fieldHeight)

        list.config = c
        list.frame = listRect
    }

    private func refilter() {
        list.matches = Fuzzy.filter(items, query: field.stringValue,
                                    history: config.sortByUsage ? history : nil, keepOrder: keepOrder)
    }

    private func accept() {
        guard !finished else { return }
        finished = true
        if list.matches.indices.contains(list.selected) {
            onFinish?(.chose(list.matches[list.selected].item))
        } else {
            onFinish?(.typed(field.stringValue))
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onFinish?(.cancelled)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): list.move(by: 1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): list.move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): list.move(by: config.lines)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): list.move(by: -config.lines)
        case #selector(NSResponder.insertNewline(_:)): accept()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if config.closeOnFocusLoss { cancel() }
    }
}
