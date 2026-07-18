import AppCore
import Foundation

public enum MarkdownFormatter {
    public static func render(
        frontMatter: [String: FrontMatterValue],
        body: String
    ) -> String {
        guard !frontMatter.isEmpty else { return body }
        let lines = frontMatter.keys.sorted().map { key in
            "\(key): \(encode(frontMatter[key] ?? .null))"
        }
        return (["---"] + lines + ["---", body]).joined(separator: "\n")
    }

    public static func updatingFrontMatter(
        in markdown: String,
        changes: [String: FrontMatterValue]
    ) throws -> String {
        var result = markdown
        for key in changes.keys.sorted() {
            guard isValidKey(key), let value = changes[key] else {
                throw TGSidianError.invalidFrontMatter("Invalid top-level key: \(key)")
            }
            result = try updateOne(in: result, key: key, value: value)
        }
        return result
    }

    private static func updateOne(
        in markdown: String,
        key: String,
        value: FrontMatterValue
    ) throws -> String {
        let newline = markdown.contains("\r\n") ? "\r\n" : "\n"
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            let prefix = ["---", "\(key): \(encode(value))", "---"].joined(separator: newline)
            return prefix + newline + markdown
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else {
            throw TGSidianError.invalidFrontMatter("Opening delimiter has no closing delimiter")
        }

        let keyPrefix = key + ":"
        var found: Int?
        for index in 1..<closing {
            let startsIndented = lines[index].first?.isWhitespace == true
            if !startsIndented && lines[index].hasPrefix(keyPrefix) {
                let suffix = lines[index].dropFirst(keyPrefix.count)
                if suffix.isEmpty || suffix.first?.isWhitespace == true {
                    found = index
                    break
                }
            }
        }

        let replacement = "\(key): \(encode(value))"
        if let found {
            var end = found + 1
            while end < closing {
                let candidate = lines[end]
                if candidate.first?.isWhitespace == true || candidate.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                    end += 1
                } else {
                    break
                }
            }
            lines.replaceSubrange(found..<end, with: [replacement])
        } else {
            lines.insert(replacement, at: closing)
        }
        return lines.joined(separator: newline)
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
    }

    private static func encode(_ value: FrontMatterValue) -> String {
        switch value {
        case let .string(value): quoteIfNeeded(value)
        case let .strings(values): "[" + values.map(quoteIfNeeded).joined(separator: ", ") + "]"
        case let .bool(value): value ? "true" : "false"
        case let .integer(value): String(value)
        case let .number(value): String(value)
        case .null: "null"
        }
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let requiresQuotes = value.isEmpty
            || value.contains(":")
            || value.contains("#")
            || value.contains(",")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
            || ["true", "false", "null", "yes", "no"].contains(value.lowercased())
        guard requiresQuotes else { return value }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
