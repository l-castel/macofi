import AppKit

/// All user-tunable settings. Every field has a default, so the config file
/// only needs to contain the values you want to change.
struct Config {
    // [window]
    var width: CGFloat = 640
    var lines: Int = 8
    var borderRadius: CGFloat = 12
    var borderWidth: CGFloat = 2
    var padding: CGFloat = 14
    var shadow = true
    var opacity: CGFloat = 1.0
    var verticalOffset: CGFloat = 0
    var closeOnFocusLoss = true

    // [input]
    var prompt = ""
    var placeholder = "Search applications…"
    var separatorWidth: CGFloat = 1

    // [list]
    var showIcons = true
    var iconSize: CGFloat = 24
    var rowHeight: CGFloat = 36
    var rowRadius: CGFloat = 8
    var rowSpacing: CGFloat = 2
    var highlightMatches = true
    var boldMatches = false

    // [font]
    var fontFamily = "monospace"
    var fontSize: CGFloat = 15
    var fontWeight = "regular"
    var inputFontSize: CGFloat = 18

    // [colors]
    var background = NSColor(hex: "#1a1b26")!
    var foreground = NSColor(hex: "#a9b1d6")!
    var border = NSColor(hex: "#7aa2f7")!
    var selectionBackground = NSColor(hex: "#292e42")!
    var selectionForeground = NSColor(hex: "#c0caf5")!
    var match = NSColor(hex: "#7dcfff")!
    var placeholderColor = NSColor(hex: "#565f89")!
    var promptColor = NSColor(hex: "#7aa2f7")!
    var cursor = NSColor(hex: "#c0caf5")!
    var inputBackground = NSColor(hex: "#00000000")!
    var separator = NSColor(hex: "#292e42")!

    // [search]
    var paths = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "~/Applications",
        "/System/Library/CoreServices/Finder.app",
    ]
    var excludes: [String] = []
    var sortByUsage = true

    // [daemon]
    var hotkey = "alt+space"
    var reloadHotkey = "alt+shift+r"

    // [theme]
    var colorsFile: String?

    // MARK: - Derived

    var font: NSFont { Config.makeFont(family: fontFamily, size: fontSize, weight: fontWeight) }
    var inputFont: NSFont { Config.makeFont(family: fontFamily, size: inputFontSize, weight: fontWeight) }
    var boldFont: NSFont { NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }

    private static var warnedFonts = Set<String>()

    static func makeFont(family: String, size: CGFloat, weight: String) -> NSFont {
        let w: NSFont.Weight
        switch weight.lowercased() {
        case "thin": w = .thin
        case "light": w = .light
        case "medium": w = .medium
        case "semibold": w = .semibold
        case "bold": w = .bold
        case "heavy", "black": w = .heavy
        default: w = .regular
        }
        switch family.lowercased() {
        case "monospace", "mono": return .monospacedSystemFont(ofSize: size, weight: w)
        case "system", "sans", "sans-serif", "": return .systemFont(ofSize: size, weight: w)
        default: break
        }
        // Accept either a PostScript name ("JetBrainsMonoNF-Regular") or a family name ("JetBrainsMono Nerd Font").
        if let f = NSFont(name: family, size: size) { return f }
        let nsWeight: Int = [NSFont.Weight.thin: 3, .light: 4, .regular: 5, .medium: 6, .semibold: 8, .bold: 9, .heavy: 11][w] ?? 5
        if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: nsWeight, size: size) { return f }
        if warnedFonts.insert(family).inserted { warn("font '\(family)' not found, falling back to monospace") }
        return .monospacedSystemFont(ofSize: size, weight: w)
    }

    // MARK: - Loading

    static var defaultPath: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "~/.config"
        return (base as NSString).expandingTildeInPath + "/macofi/config.toml"
    }

    static func load(path: String?) -> Config {
        warnedFonts.removeAll()
        collectedWarnings.removeAll()
        var config = Config()
        let file = path.map { ($0 as NSString).expandingTildeInPath } ?? defaultPath
        // No config file is fine: defaults, plus the matugen colours if there are any.
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? {
            if path != nil { warn("could not read config at \(file), using defaults") }
            return ""
        }()
        let table: [String: TOMLValue]
        do {
            table = try parseTOML(text)
        } catch {
            warn("\(file): \(error), using defaults")
            return config
        }
        for (key, value) in table {
            config.apply(key: key, value: value)
        }
        if let colorsFile = config.colorsFile {
            config.applyColorsFile((colorsFile as NSString).expandingTildeInPath)
        } else if FileManager.default.fileExists(atPath: Matugen.outputPath) {
            config.applyColorsFile(Matugen.outputPath) // written by matugen once allowed (see Matugen.swift)
        }
        config.clampToSaneRanges()
        _ = config.font // resolve now so a missing font is reported with the other warnings
        return config
    }

    /// Out-of-range sizes can't crash layout or divide by zero later; each clamp is reported.
    private mutating func clampToSaneRanges() {
        func clamp(_ value: inout CGFloat, _ range: ClosedRange<CGFloat>, _ key: String) {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if clamped != value {
                warn("'\(key)' = \(value) is out of range, using \(clamped)")
                value = clamped
            }
        }
        clamp(&width, 200...4000, "window.width")
        clamp(&borderRadius, 0...200, "window.border_radius")
        clamp(&borderWidth, 0...50, "window.border_width")
        clamp(&padding, 0...200, "window.padding")
        clamp(&opacity, 0.1...1, "window.opacity")
        clamp(&verticalOffset, -4000...4000, "window.vertical_offset")
        clamp(&separatorWidth, 0...50, "input.separator_width")
        clamp(&iconSize, 4...256, "list.icon_size")
        clamp(&rowHeight, 8...400, "list.row_height")
        clamp(&rowRadius, 0...200, "list.row_radius")
        clamp(&rowSpacing, 0...200, "list.row_spacing")
        clamp(&fontSize, 4...200, "font.size")
        clamp(&inputFontSize, 4...200, "font.input_size")
    }

    /// Overlays the [colors] section of a generated file (e.g. written by matugen or pywal).
    /// Colors it doesn't define keep the values from the main config.
    private mutating func applyColorsFile(_ file: String) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            return warn("could not read colors_file \(file), using [colors] from the config")
        }
        do {
            for (key, value) in try parseTOML(text) {
                guard key.hasPrefix("colors.") else {
                    warn("\(file): ignoring '\(key)', only [colors] is read from a colors_file")
                    continue
                }
                apply(key: key, value: value)
            }
        } catch {
            warn("\(file): \(error)")
        }
    }

    private mutating func apply(key: String, value: TOMLValue) {
        func num() -> CGFloat? {
            if case .number(let n) = value, n.isFinite { return CGFloat(n) }
            warn("'\(key)' should be a finite number"); return nil
        }
        func bool() -> Bool? {
            if case .bool(let b) = value { return b }
            warn("'\(key)' should be true or false"); return nil
        }
        func str() -> String? {
            if case .string(let s) = value { return s }
            warn("'\(key)' should be a string"); return nil
        }
        func color() -> NSColor? {
            guard let s = str() else { return nil }
            if let c = NSColor(hex: s) { return c }
            warn("'\(key)': invalid color '\(s)' (use #RGB, #RRGGBB or #RRGGBBAA)"); return nil
        }
        func list() -> [String]? {
            if case .array(let a) = value { return a }
            warn("'\(key)' should be an array of strings"); return nil
        }

        switch key {
        case "window.width": width = num() ?? width
        case "window.lines":
            // Clamp before converting: Int() traps on huge values.
            if let n = num() {
                let clamped = min(max(n.rounded(), 1), 50)
                if clamped != n { warn("'window.lines' = \(n) is out of range, using \(Int(clamped))") }
                lines = Int(clamped)
            }
        case "window.border_radius": borderRadius = num() ?? borderRadius
        case "window.border_width": borderWidth = num() ?? borderWidth
        case "window.padding": padding = num() ?? padding
        case "window.shadow": shadow = bool() ?? shadow
        case "window.opacity": opacity = num() ?? opacity
        case "window.vertical_offset": verticalOffset = num() ?? verticalOffset
        case "window.close_on_focus_loss": closeOnFocusLoss = bool() ?? closeOnFocusLoss

        case "input.prompt": prompt = str() ?? prompt
        case "input.placeholder": placeholder = str() ?? placeholder
        case "input.separator_width": separatorWidth = num() ?? separatorWidth

        case "list.show_icons": showIcons = bool() ?? showIcons
        case "list.icon_size": iconSize = num() ?? iconSize
        case "list.row_height": rowHeight = num() ?? rowHeight
        case "list.row_radius": rowRadius = num() ?? rowRadius
        case "list.row_spacing": rowSpacing = num() ?? rowSpacing
        case "list.highlight_matches": highlightMatches = bool() ?? highlightMatches
        case "list.bold_matches": boldMatches = bool() ?? boldMatches

        case "font.family": fontFamily = str() ?? fontFamily
        case "font.size": fontSize = num() ?? fontSize
        case "font.weight": fontWeight = str() ?? fontWeight
        case "font.input_size": inputFontSize = num() ?? inputFontSize

        case "colors.background": background = color() ?? background
        case "colors.foreground": foreground = color() ?? foreground
        case "colors.border": border = color() ?? border
        case "colors.selection_background": selectionBackground = color() ?? selectionBackground
        case "colors.selection_foreground": selectionForeground = color() ?? selectionForeground
        case "colors.match": match = color() ?? match
        case "colors.placeholder": placeholderColor = color() ?? placeholderColor
        case "colors.prompt": promptColor = color() ?? promptColor
        case "colors.cursor": cursor = color() ?? cursor
        case "colors.input_background": inputBackground = color() ?? inputBackground
        case "colors.separator": separator = color() ?? separator

        case "search.paths": paths = list() ?? paths
        case "search.exclude": excludes = list() ?? excludes
        case "search.sort_by_usage": sortByUsage = bool() ?? sortByUsage

        case "daemon.hotkey": hotkey = str() ?? hotkey
        case "daemon.reload_hotkey": reloadHotkey = str() ?? reloadHotkey

        case "theme.colors_file": colorsFile = str() ?? colorsFile

        default: warn("unknown config key '\(key)'")
        }
    }
}

/// Every warning since the last reset, so the daemon can report config problems on screen
/// (its stderr usually goes nowhere under launchd).
var collectedWarnings: [String] = []

func warn(_ message: String) {
    collectedWarnings.append(message)
    FileHandle.standardError.write("macofi: \(message)\n".data(using: .utf8)!)
}

extension NSColor {
    /// Parses #RGB, #RRGGBB or #RRGGBBAA.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 6 { s += "ff" }
        guard s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 24) & 0xff) / 255,
                  green: CGFloat((v >> 16) & 0xff) / 255,
                  blue: CGFloat((v >> 8) & 0xff) / 255,
                  alpha: CGFloat(v & 0xff) / 255)
    }
}

// MARK: - Minimal TOML subset parser
//
// Supports: [section] headers, `key = value` pairs, # comments, and values that are
// "strings" / 'strings', numbers, booleans, and (possibly multi-line) arrays of strings.
// Keys are returned flattened as "section.key".

enum TOMLValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([String])
}

struct TOMLError: Error, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "line \(line): \(message)" }
}

func parseTOML(_ text: String) throws -> [String: TOMLValue] {
    var result: [String: TOMLValue] = [:]
    var section = ""
    let lines = text.components(separatedBy: .newlines)
    var i = 0
    while i < lines.count {
        let lineNo = i + 1
        var line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
        i += 1
        if line.isEmpty { continue }

        if line.hasPrefix("[") {
            guard line.hasSuffix("]") else { throw TOMLError(line: lineNo, message: "bad section header") }
            section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            continue
        }
        guard let eq = line.firstIndex(of: "=") else { throw TOMLError(line: lineNo, message: "expected key = value") }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

        // Multi-line arrays: keep consuming lines until the closing bracket.
        if raw.hasPrefix("[") {
            while !raw.hasSuffix("]") && i < lines.count {
                line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
                raw += " " + line
                i += 1
            }
        }
        let fullKey = section.isEmpty ? key : "\(section).\(key)"
        result[fullKey] = try parseValue(raw, line: lineNo)
    }
    return result
}

private func stripComment(_ line: String) -> String {
    var quote: Character? = nil
    var escaped = false
    for (idx, ch) in zip(line.indices, line) {
        if let q = quote {
            // Only basic ("...") strings have escapes; \" doesn't end them.
            if escaped { escaped = false }
            else if ch == "\\" && q == "\"" { escaped = true }
            else if ch == q { quote = nil }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch == "#" {
            return String(line[..<idx])
        }
    }
    return line
}

private func parseValue(_ raw: String, line: Int) throws -> TOMLValue {
    if raw == "true" { return .bool(true) }
    if raw == "false" { return .bool(false) }
    if let s = parseString(raw) { return .string(s) }
    if let n = Double(raw.replacingOccurrences(of: "_", with: "")) { return .number(n) }
    if raw.hasPrefix("[") && raw.hasSuffix("]") {
        let inner = raw.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" && q == "\"" { escaped = true }
                else if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                items.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        var strings: [String] = []
        for item in items.map({ $0.trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            guard let s = parseString(item) else { throw TOMLError(line: line, message: "arrays may only contain strings") }
            strings.append(s)
        }
        return .array(strings)
    }
    throw TOMLError(line: line, message: "invalid value '\(raw)'")
}

private func parseString(_ raw: String) -> String? {
    guard raw.count >= 2, let first = raw.first, first == "\"" || first == "'", raw.last == first else { return nil }
    let body = String(raw.dropFirst().dropLast())
    if first == "'" { return body }
    // One left-to-right pass, so "\\n" stays a backslash followed by n.
    var result = ""
    var escaping = false
    for ch in body {
        if escaping {
            switch ch {
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(ch) // \" and \\ (and anything unknown) map to the character itself
            }
            escaping = false
        } else if ch == "\\" {
            escaping = true
        } else {
            result.append(ch)
        }
    }
    return result
}
