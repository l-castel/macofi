import AppKit

let usage = """
usage: macofi [options]

  (no options)      show the app picker once, launch the selection, exit
  --daemon          stay running in the background; the hotkey from
                    [daemon] hotkey toggles the picker. Opening Macofi.app
                    from Finder, Spotlight or Login Items does the same
  --dmenu           read lines from stdin, print the chosen one to stdout
                    (exit 1 if cancelled)
  --placeholder S   override the input placeholder text
  --prompt S        override the prompt shown before the input
  --config PATH     use PATH instead of \(Config.defaultPath)
  --show            ask the running daemon to show the picker (instant;
                    falls back to a one-shot picker if no daemon runs)
  --print-config    print the default config file with all options
  --version         print the version
  -h, --help        show this help
"""

enum Mode { case once, daemon, dmenu, show }

/// Posted to ask the running daemon to show its picker.
let showNotification = Notification.Name("dev.macofi.show")

/// Held for the daemon's lifetime, so only one daemon runs (Carbon doesn't reject the same
/// hotkey registered by two processes, so they would both respond).
func acquireDaemonLock() -> Bool {
    let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? "~/.local/state"
    let dir = (base as NSString).expandingTildeInPath + "/macofi"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let fd = open(dir + "/daemon.lock", O_CREAT | O_RDWR, 0o644)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0 // fd stays open until exit
}

func daemonIsRunning() -> Bool {
    let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? "~/.local/state"
    let fd = open((base as NSString).expandingTildeInPath + "/macofi/daemon.lock", O_RDONLY)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return true
}

func askDaemonToShow() {
    DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil,
                                                                  userInfo: nil, deliverImmediately: true)
}

var mode = Mode.once
var configPath: String?
var placeholderOverride: String?
var promptOverride: String?

/// Opened as an app (Finder, Spotlight, Login Items, `open`) rather than run as a command.
let openedAsApp = ProcessInfo.processInfo.environment["MACOFI_LAUNCHSERVICES"] == "1"
if openedAsApp { mode = .daemon }

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case _ where arg.hasPrefix("-psn_"): continue // process serial number some macOS versions pass to apps
    case "--version": print("macofi \(macofiVersion)"); exit(0)
    case "--daemon": mode = .daemon
    case "--show": mode = .show
    case "--dmenu": mode = .dmenu
    case "--config": configPath = args.popFirst()
    case "--placeholder": placeholderOverride = args.popFirst()
    case "--prompt", "-p": promptOverride = args.popFirst()
    case "--print-config": print(defaultConfigText, terminator: ""); exit(0)
    case "-h", "--help": print(usage); exit(0)
    default: warn("unknown option '\(arg)'"); print(usage); exit(2)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let picker = Picker()
    var history = History()
    let toast = Toast()
    var hotkey: Hotkey?
    var reloadHotkey: Hotkey?
    var dmenuItems: [Item] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        picker.onFinish = { [weak self] outcome in self?.finish(outcome) }

        switch mode {
        case .once, .show: // .show became .once before launch when no daemon was running
            show()
        case .dmenu:
            if isatty(STDIN_FILENO) != 0 {
                warn("--dmenu reads its choices from stdin, e.g. printf 'a\\nb\\n' | macofi --dmenu")
                exit(2)
            }
            let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            dmenuItems = input.split(whereSeparator: \.isNewline).map { Item(title: String($0)) }
            show()
        case .daemon:
            let config = loadConfig()
            registerHotkeys(config, previous: nil)
            if hotkey == nil {
                guard openedAsApp else { exit(1) }
                // No terminal to print to: say why on screen before quitting.
                toast.show("macofi: could not register hotkey '\(config.hotkey)'.\nIs another app or macofi instance using it?",
                           config: config, isError: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(1) }
                return
            }
            DistributedNotificationCenter.default().addObserver(forName: showNotification, object: nil, queue: .main) {
                [weak self] _ in
                guard let self, !self.picker.isVisible else { return }
                self.show()
            }
            if openedAsApp {
                toast.show("macofi is running · press \(config.hotkey)", config: config)
            }
            // `pkill -USR1 -x macofi` does the same as the reload hotkey, for scripts.
            signal(SIGUSR1, SIG_IGN)
            reloadSignal.setEventHandler { [weak self] in self?.reload() }
            reloadSignal.resume()
        }
    }

    /// Registers both daemon hotkeys. If the toggle hotkey can't be registered, `previous`
    /// (the spec that was working) is restored so a typo never leaves the picker unreachable.
    func registerHotkeys(_ config: Config, previous: String?) {
        hotkey = nil // unregister first so a spec that didn't change can be registered again
        reloadHotkey = nil
        hotkey = Hotkey(config.hotkey) { [weak self] in self?.toggle() }
        if hotkey == nil, let previous {
            warn("keeping the previous hotkey '\(previous)'")
            hotkey = Hotkey(previous) { [weak self] in self?.toggle() }
            activeHotkey = previous
        } else {
            activeHotkey = config.hotkey
        }
        if !config.reloadHotkey.isEmpty {
            reloadHotkey = Hotkey(config.reloadHotkey) { [weak self] in self?.reload() }
        }
    }
    var activeHotkey: String?
    let reloadSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)

    /// Hard reload: everything the daemon only reads at startup (hotkeys, launch history),
    /// plus a fresh read of the config and colors_file, with the result shown on screen.
    func reload() {
        if picker.isVisible { picker.hide() }
        history = History()
        let config = loadConfig()
        registerHotkeys(config, previous: activeHotkey)

        if collectedWarnings.isEmpty {
            toast.show("Config reloaded", config: config)
        } else {
            let n = collectedWarnings.count
            let shown = collectedWarnings.prefix(3).joined(separator: "\n")
            let more = n > 3 ? "\n…and \(n - 3) more" : ""
            toast.show("Config reloaded with \(n) warning\(n == 1 ? "" : "s"):\n\(shown)\(more)", config: config, isError: true)
        }
    }

    /// Opening the app again while it runs (e.g. double-clicking it) shows the picker.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mode == .daemon && !picker.isVisible { show() }
        return false
    }

    func loadConfig() -> Config {
        var config = Config.load(path: configPath)
        if let placeholderOverride { config.placeholder = placeholderOverride }
        if let promptOverride { config.prompt = promptOverride }
        if mode == .dmenu && placeholderOverride == nil && config.placeholder == Config().placeholder {
            config.placeholder = "Search…"
        }
        return config
    }

    /// Config and app list are re-read on every show, so edits apply immediately in daemon mode.
    func show() {
        let config = loadConfig()
        if mode == .dmenu {
            picker.show(config: config, items: dmenuItems, history: nil, keepOrder: true)
        } else {
            picker.show(config: config, items: AppScanner.scan(config: config), history: history, keepOrder: false)
        }
    }

    func toggle() {
        if picker.isVisible {
            picker.hide()
            NSApp.hide(nil)
        } else {
            show()
        }
    }

    func finish(_ outcome: Picker.Outcome) {
        picker.hide()
        switch (mode, outcome) {
        case (.dmenu, .chose(let item)): print(item.title); exit(0)
        case (.dmenu, .typed(let text)): print(text); exit(text.isEmpty ? 1 : 0)
        case (.dmenu, .cancelled): exit(1)

        case (_, .chose(let item)):
            history.record(item)
            AppScanner.launch(item) { if mode == .once { exit(0) } }
        case (.once, _): exit(0)
        case (_, _): NSApp.hide(nil) // daemon: give focus back to the previous app
        }
    }

    /// Accessory apps still need an Edit menu for cmd+c / cmd+v / cmd+a to work in the text field.
    func installMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

if mode == .show {
    if daemonIsRunning() { askDaemonToShow(); exit(0) }
    mode = .once
}
if mode == .daemon && !acquireDaemonLock() {
    // Already running: opening the app again just shows the picker.
    if openedAsApp { askDaemonToShow(); exit(0) }
    warn("a daemon is already running (use --show to open its picker)")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
