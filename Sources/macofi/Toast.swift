import AppKit

/// A short-lived message centered on screen, styled like the picker. It never takes focus.
final class Toast {
    private let panel: NSPanel
    private let root = RootView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        root.addSubview(label)
        panel.contentView = root
    }

    func show(_ message: String, config: Config, isError: Bool = false) {
        let font = config.font
        label.stringValue = message
        label.font = font
        label.textColor = isError ? NSColor(srgbRed: 1, green: 0.42, blue: 0.42, alpha: 1) : config.foreground
        label.alignment = .center
        label.preferredMaxLayoutWidth = min(config.width, 520) - 2 * config.padding
        let size = label.fittingSize
        let pad = config.padding
        let frame = NSSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        label.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(NSRect(x: round(screen.frame.midX - frame.width / 2),
                              y: round(screen.frame.midY - frame.height / 2 + config.verticalOffset),
                              width: frame.width, height: frame.height), display: true)
        var style = config
        if isError { style.border = label.textColor! }
        style.separatorWidth = 0
        root.inputRect = .zero
        root.apply(style)
        panel.hasShadow = config.shadow
        panel.alphaValue = config.opacity
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 1.5), execute: work)
    }
}
