import AppKit

/// One selectable row. In app mode `path` points to a .app bundle; in dmenu mode it is nil.
final class Item {
    let title: String
    let path: String?
    private var cachedIcon: NSImage?

    init(title: String, path: String? = nil) {
        self.title = title
        self.path = path
    }

    /// Loaded lazily so we only pay for icons that are actually drawn.
    var icon: NSImage? {
        guard let path else { return nil }
        if cachedIcon == nil { cachedIcon = NSWorkspace.shared.icon(forFile: path) }
        return cachedIcon
    }
}

enum AppScanner {
    static func scan(config: Config) -> [Item] {
        let fm = FileManager.default
        var seen = Set<String>()
        var items: [Item] = []
        let excludes = Set(config.excludes.map { $0.lowercased() })

        func add(_ path: String) {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(resolved).inserted else { return }
            let name = (fm.displayName(atPath: path) as NSString).deletingPathExtension
            if excludes.contains(name.lowercased()) { return }
            items.append(Item(title: name, path: path))
        }

        func walk(_ dir: String, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries where !entry.hasPrefix(".") {
                let full = (dir as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    add(full)
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        walk(full, depth: depth - 1)
                    }
                }
            }
        }

        for raw in config.paths {
            let path = (raw as NSString).expandingTildeInPath
            if path.hasSuffix(".app") {
                if fm.fileExists(atPath: path) { add(path) }
            } else {
                walk(path, depth: 1)
            }
        }
        return items
    }

    static func launch(_ item: Item, completion: @escaping () -> Void) {
        guard let path = item.path else { return completion() }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, error in
            if let error { warn("failed to launch \(item.title): \(error.localizedDescription)") }
            DispatchQueue.main.async(execute: completion)
        }
    }
}

/// Launch counts, used to float frequently used apps to the top.
final class History {
    private let file: String
    private(set) var counts: [String: Int] = [:]

    init() {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? "~/.local/state"
        file = (base as NSString).expandingTildeInPath + "/macofi/history.json"
        counts = readFile()
    }

    private func readFile() -> [String: Int] {
        guard let data = FileManager.default.contents(atPath: file),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return decoded
    }

    func count(for item: Item) -> Int { counts[item.path ?? item.title] ?? 0 }

    /// Re-reads the file first: one-shot runs and the daemon each hold their own copy,
    /// and writing a stale copy would drop the other's launches.
    func record(_ item: Item) {
        counts = readFile()
        counts[item.path ?? item.title, default: 0] += 1
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(counts) {
            try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
    }
}

// MARK: - Fuzzy matching

struct Match {
    let item: Item
    let score: Int
    /// UTF-16 ranges of matched characters, for highlighting.
    let ranges: [NSRange]
}

enum Fuzzy {
    /// Subsequence match with bonuses for prefix, word starts and consecutive runs.
    /// Returns nil when `query` is not a subsequence of `text` (case-insensitive).
    static func match(_ query: String, in text: String) -> (score: Int, ranges: [NSRange])? {
        if query.isEmpty { return (0, []) }
        let q = Array(query.lowercased())
        let chars = Array(text)
        var qi = 0
        var score = 0
        var lastMatch = -2
        var matched: [Int] = []

        for (ti, ch) in chars.enumerated() where qi < q.count {
            guard ch.lowercased() == String(q[qi]) else { continue }
            var bonus = 1
            if ti == 0 { bonus += 8 }
            else if !chars[ti - 1].isLetter && !chars[ti - 1].isNumber { bonus += 6 }
            else if ch.isUppercase && chars[ti - 1].isLowercase { bonus += 5 }
            if ti == lastMatch + 1 { bonus += 5 }
            else if lastMatch >= 0 { score -= min(ti - lastMatch - 1, 5) }
            score += bonus
            lastMatch = ti
            matched.append(ti)
            qi += 1
        }
        guard qi == q.count else { return nil }
        score -= chars.count / 4 // prefer shorter names

        // Convert Character offsets to UTF-16 ranges.
        var ranges: [NSRange] = []
        var utf16Offset = 0
        var mi = 0
        for (ti, ch) in chars.enumerated() where mi < matched.count {
            let len = ch.utf16.count
            if matched[mi] == ti {
                if let last = ranges.last, last.location + last.length == utf16Offset {
                    ranges[ranges.count - 1].length += len
                } else {
                    ranges.append(NSRange(location: utf16Offset, length: len))
                }
                mi += 1
            }
            utf16Offset += len
        }
        return (score, ranges)
    }

    /// Ranks items by match score (plus launch count when `history` is given).
    /// Ties keep alphabetical order, or input order when `keepOrder` is set (dmenu mode).
    static func filter(_ items: [Item], query: String, history: History?, keepOrder: Bool) -> [Match] {
        var results: [(Match, Int)] = []
        for (index, item) in items.enumerated() {
            guard let m = match(query, in: item.title) else { continue }
            let usage = history.map { min($0.count(for: item), 20) } ?? 0
            results.append((Match(item: item, score: m.score * 4 + usage, ranges: m.ranges), index))
        }
        results.sort { a, b in
            if a.0.score != b.0.score { return a.0.score > b.0.score }
            if keepOrder { return a.1 < b.1 }
            return a.0.item.title.localizedCaseInsensitiveCompare(b.0.item.title) == .orderedAscending
        }
        return results.map { $0.0 }
    }
}
