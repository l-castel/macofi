import AppKit

/// Optional matugen integration. macofi never needs matugen: without it the colours come
/// from [colors] in the config (Tokyo Night by default). When matugen is installed, macofi
/// asks once (first daemon start, or `macofi --setup-matugen`) whether it may register its
/// template in the matugen config. The answer is stored in ~/.config/macofi/matugen-consent.
enum Matugen {
    static let section = "[templates.macofi]"
    static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    static var configDir: String { (ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? home + "/.config") + "/macofi" }
    static var consentFile: String { configDir + "/matugen-consent" }
    static var templatePath: String { configDir + "/matugen-template.toml" }
    static var outputPath: String { configDir + "/colors.toml" }

    /// The matugen binary, if installed (apps launched from Finder get a minimal PATH).
    static var binary: String? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let dirs = path + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin"]
        return dirs.map { $0 + "/matugen" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The config matugen actually reads: $MATUGEN_CONFIG, else the macOS default if it
    /// exists, else ~/.config/matugen/config.toml if it exists (setups using `-c`), else the default.
    static var configPath: String {
        if let p = ProcessInfo.processInfo.environment["MATUGEN_CONFIG"] { return (p as NSString).expandingTildeInPath }
        let fm = FileManager.default
        let def = home + "/Library/Application Support/com.InioX.matugen/config.toml"
        let xdg = home + "/.config/matugen/config.toml"
        return !fm.fileExists(atPath: def) && fm.fileExists(atPath: xdg) ? xdg : def
    }

    static var needsAnswer: Bool { !FileManager.default.fileExists(atPath: consentFile) && binary != nil }

    static var question: String {
        "matugen is installed. Allow macofi to add its template to \(configPath) so its colours follow your matugen theme?"
    }

    /// `--setup-matugen [--yes|--no]` from a terminal.
    static func setupFromTerminal(answer: Bool?) {
        guard binary != nil else {
            return print("matugen is not installed; macofi uses the [colors] from its config.")
        }
        let yes = answer ?? {
            print(question + " [y/N] ", terminator: "")
            return ["y", "Y", "yes"].contains(readLine()?.trimmingCharacters(in: .whitespaces) ?? "")
        }()
        print(apply(yes))
    }

    /// First daemon start without a terminal: ask with a dialog.
    static func askWithAlert() {
        let alert = NSAlert()
        alert.messageText = "Follow your matugen theme?"
        alert.informativeText = question + "\n\nYou can change this later with `macofi --setup-matugen`."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate(ignoringOtherApps: true)
        let yes = alert.runModal() == .alertFirstButtonReturn
        let result = apply(yes)
        FileHandle.standardError.write(Data("macofi: \(result)\n".utf8))
    }

    /// Records the answer and, on yes, registers the template and renders it once.
    static func apply(_ yes: Bool) -> String {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try? (yes ? "yes\n" : "no\n").write(toFile: consentFile, atomically: true, encoding: .utf8)
        guard yes else { return "Left the matugen config untouched. Run `macofi --setup-matugen` to change your mind." }
        var lines: [String] = []
        do {
            lines.append(try register() ? "Added \(section) to \(configPath)" : "\(section) is already in \(configPath)")
        } catch {
            return "could not update \(configPath): \(error.localizedDescription)"
        }
        lines.append(renderNow() ? "Rendered the current theme from your wallpaper."
                                 : "Theme will update on your next matugen run.")
        return lines.joined(separator: "\n")
    }

    private static var block: String {
        "\n# Added by macofi (macofi --setup-matugen)\n\(section)\ninput_path = '\(templatePath)'\noutput_path = '\(outputPath)'\n"
    }

    /// Writes the template (keeping user edits) and appends the block if missing.
    private static func register() throws -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: templatePath) {
            try matugenTemplate.write(toFile: templatePath, atomically: true, encoding: .utf8)
        }
        let current = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if current.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == section }) {
            return false
        }
        try fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let text = (current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "[config]\n" : current) + block
        try text.write(toFile: configPath, atomically: true, encoding: .utf8)
        return true
    }

    /// matugen keeps no "current theme", so derive it from the current wallpaper. Only
    /// macofi's template is rendered (a throwaway config): no other output or hook runs.
    private static func renderNow() -> Bool {
        guard let bin = binary, let screen = NSScreen.main,
              let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen)?.path,
              FileManager.default.fileExists(atPath: wallpaper) else { return false }
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let tmp = NSTemporaryDirectory() + "macofi-matugen-\(getpid()).toml"
        guard (try? ("[config]\n" + block).write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-c", tmp, "image", wallpaper, "-m", dark ? "dark" : "light", "--source-color-index", "0", "-q"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
