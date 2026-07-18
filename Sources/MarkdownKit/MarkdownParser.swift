import AppCore
import Foundation

public struct MarkdownParser: Sendable {
    private let instrument: any PerformanceInstrumenting

    public init(instrument: any PerformanceInstrumenting = NoopPerformanceInstrument()) {
        self.instrument = instrument
    }

    public func parse(_ markdown: String, path: RelativePath? = nil) -> ParsedNote {
        instrument.begin(.parse)
        defer { instrument.end(.parse) }

        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var diagnostics: [MarkdownDiagnostic] = []
        var rawFrontMatter: String?
        var fields: [String: FrontMatterValue] = [:]
        var bodyLines = allLines
        var bodyLineOffset = 0

        if allLines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let closing = allLines.dropFirst().firstIndex(where: {
                let value = $0.trimmingCharacters(in: .whitespaces)
                return value == "---" || value == "..."
            }) {
                let frontLines = Array(allLines[1..<closing])
                rawFrontMatter = frontLines.joined(separator: "\n")
                let parsed = parseFrontMatter(frontLines)
                fields = parsed.fields
                diagnostics.append(contentsOf: parsed.diagnostics)
                bodyLines = Array(allLines.dropFirst(closing + 1))
                bodyLineOffset = closing + 1
            } else {
                diagnostics.append(MarkdownDiagnostic(
                    severity: .error,
                    message: "Opening front matter delimiter has no closing delimiter",
                    line: 1
                ))
            }
        }

        let body = bodyLines.joined(separator: "\n")
        let headings = parseHeadings(bodyLines, offset: bodyLineOffset)
        let links = parseWikiLinks(bodyLines, offset: bodyLineOffset)
        let tasks = parseTasks(bodyLines, offset: bodyLineOffset)
        let tags = parseTags(body: body, fields: fields)

        let frontTitle = fields["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headingTitle = headings.first(where: { $0.level == 1 })?.text
        let pathTitle = path?.nameWithoutExtension
        let title = [frontTitle, headingTitle, pathTitle, "Untitled"]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "Untitled"

        return ParsedNote(
            title: title,
            body: body,
            rawFrontMatter: rawFrontMatter,
            frontMatter: fields,
            headings: headings,
            links: links,
            tags: tags,
            tasks: tasks,
            diagnostics: diagnostics
        )
    }

    private func parseFrontMatter(_ lines: [String]) -> (
        fields: [String: FrontMatterValue],
        diagnostics: [MarkdownDiagnostic]
    ) {
        var fields: [String: FrontMatterValue] = [:]
        var diagnostics: [MarkdownDiagnostic] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true {
                diagnostics.append(MarkdownDiagnostic(
                    severity: .warning,
                    message: "Nested YAML is preserved but not indexed by the foundation parser",
                    line: index + 2
                ))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                diagnostics.append(MarkdownDiagnostic(
                    severity: .error,
                    message: "Expected a top-level key and colon",
                    line: index + 2
                ))
                continue
            }

            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                diagnostics.append(MarkdownDiagnostic(
                    severity: .error,
                    message: "Front matter key is empty",
                    line: index + 2
                ))
                continue
            }

            let valueStart = line.index(after: colon)
            let rawValue = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            if rawValue.isEmpty {
                var items: [String] = []
                var cursor = index + 1
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("- ") else { break }
                    items.append(unquote(String(candidate.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                    cursor += 1
                }
                if !items.isEmpty {
                    fields[key] = .strings(items)
                    index = cursor - 1
                } else {
                    fields[key] = .null
                }
            } else {
                fields[key] = parseScalar(rawValue)
            }
        }

        return (fields, diagnostics)
    }

    private func parseScalar(_ raw: String) -> FrontMatterValue {
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let inner = raw.dropFirst().dropLast()
            let values = splitInlineList(String(inner)).map(unquote)
            return .strings(values)
        }

        let lowered = raw.lowercased()
        if ["true", "yes"].contains(lowered) { return .bool(true) }
        if ["false", "no"].contains(lowered) { return .bool(false) }
        if ["null", "~"].contains(lowered) { return .null }
        if let integer = Int(raw) { return .integer(integer) }
        if let number = Double(raw) { return .number(number) }
        return .string(unquote(raw))
    }

    private func splitInlineList(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?

        for character in value {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                current.append(character)
            } else if character == "," && quote == nil {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func parseHeadings(_ lines: [String], offset: Int) -> [MarkdownHeading] {
        lines.enumerated().compactMap { index, line in
            let hashes = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
            let text = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
            return MarkdownHeading(
                level: hashes,
                text: text,
                slug: slug(text),
                line: index + offset + 1
            )
        }
    }

    private func parseWikiLinks(_ lines: [String], offset: Int) -> [WikiLink] {
        let expression = try? NSRegularExpression(
            pattern: #"\[\[([^\]|#]+)(?:#([^\]|]+))?(?:\|([^\]]+))?\]\]"#
        )
        guard let expression else { return [] }

        return lines.enumerated().flatMap { index, line -> [WikiLink] in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return expression.matches(in: line, range: range).compactMap { match in
                guard let targetRange = Range(match.range(at: 1), in: line) else { return nil }
                let heading = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                let alias = Range(match.range(at: 3), in: line).map { String(line[$0]) }
                return WikiLink(
                    rawTarget: String(line[targetRange]).trimmingCharacters(in: .whitespaces),
                    heading: heading?.trimmingCharacters(in: .whitespaces),
                    alias: alias?.trimmingCharacters(in: .whitespaces),
                    line: index + offset + 1
                )
            }
        }
    }

    private func parseTasks(_ lines: [String], offset: Int) -> [MarkdownTask] {
        let expression = try? NSRegularExpression(pattern: #"^\s*[-*+]\s+\[([ xX-])\]\s+(.*)$"#)
        guard let expression else { return [] }

        return lines.enumerated().compactMap { index, line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let markerRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line)
            else { return nil }
            let state: MarkdownTask.State = switch line[markerRange].lowercased() {
            case "x": .done
            case "-": .cancelled
            default: .todo
            }
            return MarkdownTask(state: state, text: String(line[textRange]), line: index + offset + 1)
        }
    }

    private func parseTags(body: String, fields: [String: FrontMatterValue]) -> Set<String> {
        var tags = Set(fields["tags"]?.stringValues.map(normalizedTag) ?? [])
        let expression = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/])#([\p{L}\p{N}_/-]+)"#)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        expression?.matches(in: body, range: range).forEach { match in
            if let tagRange = Range(match.range(at: 1), in: body) {
                tags.insert(normalizedTag(String(body[tagRange])))
            }
        }
        tags.remove("")
        return tags
    }

    private func normalizedTag(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            .lowercased()
    }

    private func slug(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
