import Foundation

/// Loads and resolves the hosts file (one host per line, optional label).
enum HostFile {
    struct Entry {
        let name: String
        let label: String
    }

    static func load(path: String) -> [Entry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var entries: [Entry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let entry = parse(line) else { continue }
            entries.append(entry)
        }
        return entries
    }

    /// Parse one line; nil for blanks and `#` comments.
    static func parse(_ line: String) -> Entry? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard !line.isEmpty, !line.hasPrefix("#"), let name = parts.first else { return nil }
        let label = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
        return Entry(name: String(name), label: String(label))
    }

    /// Append an entry (skips duplicate names), preserving existing lines and comments.
    static func add(_ entry: Entry, to path: String) {
        var lines = readLines(path) ?? []
        guard !lines.contains(where: { parse($0)?.name == entry.name }) else { return }
        var line = entry.name
        if !entry.label.isEmpty { line += " " + entry.label }
        lines.append(line)
        writeLines(lines, to: path)
    }

    /// Drop every line whose host is `name`; comments and blanks are untouched.
    static func remove(name: String, from path: String) {
        guard var lines = readLines(path) else { return }
        let kept = lines.filter { parse($0)?.name != name }
        guard kept.count != lines.count else { return }
        lines = kept
        writeLines(lines, to: path)
    }

    private static func readLines(_ path: String) -> [String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }   // trailing-newline artifact
        return lines
    }

    private static func writeLines(_ lines: [String], to path: String) {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Command-line argument, then ./hosts.txt, then next to the executable,
    /// then the repo default.
    static func resolvePath(_ arguments: [String]) -> String {
        if arguments.count > 1, !arguments[1].hasPrefix("-") {
            return (arguments[1] as NSString).expandingTildeInPath
        }
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let exeDir = Bundle.main.bundlePath
        let candidates = [
            (cwd as NSString).appendingPathComponent("hosts.txt"),
            (exeDir as NSString).appendingPathComponent("hosts.txt"),
            (NSHomeDirectory() as NSString).appendingPathComponent("QWEN/pingtester/hosts.txt"),
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate) {
            return candidate
        }
        return candidates[0]
    }
}
