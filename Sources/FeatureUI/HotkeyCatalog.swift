import SwiftUI

/// The single inventory of shortcuts currently registered by the app. Keep this in step with
/// `TGSidianApp.commands` and FeatureUI's contextual key handlers so Settings never presents a
/// key that the app does not handle.
public enum HotkeyCatalog {
    public struct Command: Identifiable, Hashable, Sendable {
        public let title: String
        public let keys: String
        public let location: String

        public var id: String { "\(location)|\(title)|\(keys)" }

        private var searchText: String {
            "\(title) \(keys) \(location)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }

        fileprivate func matches(_ query: String) -> Bool {
            let terms = query
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: { $0.isWhitespace })
            return terms.allSatisfy { searchText.contains($0) }
        }
    }

    /// Alphabetical by menu/context then command name, giving the viewer a stable, scannable
    /// order regardless of where the entries were declared in the UI.
    public static let commands: [Command] = [
        .init(title: "Cancel link selection", keys: "Esc", location: "Link picker"),
        .init(title: "Complete Wiki Link", keys: "⌃Esc", location: "Markdown"),
        .init(title: "Done", keys: "⌘↩", location: "Settings"),
        .init(title: "Focus next search result", keys: "↓", location: "Vault search"),
        .init(title: "Focus previous search result", keys: "↑", location: "Vault search"),
        .init(title: "Focus search results", keys: "↓", location: "Sidebar search"),
        .init(title: "New Note", keys: "⌘N", location: "File"),
        .init(title: "Open selected search result", keys: "↩", location: "Vault search"),
        .init(title: "Open Vault…", keys: "⌘O", location: "File"),
        .init(title: "Restore recovered edits", keys: "⌘↩", location: "Recovery"),
        .init(title: "Save extension settings", keys: "⌘↩", location: "Extension settings"),
        .init(title: "Search Vault", keys: "⌘K", location: "Navigate"),
        .init(title: "Toggle Inspector", keys: "⌥⌘I", location: "Navigate"),
        .init(title: "Toggle Task", keys: "⌘↩", location: "Markdown"),
        .init(title: "Use merged draft", keys: "⌘↩", location: "Conflict resolution"),
        .init(title: "Apply folder icon", keys: "⌘↩", location: "Folder settings")
    ]
    .sorted { left, right in
        let locationOrder = left.location.localizedStandardCompare(right.location)
        if locationOrder != .orderedSame { return locationOrder == .orderedAscending }
        let titleOrder = left.title.localizedStandardCompare(right.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return left.keys.localizedStandardCompare(right.keys) == .orderedAscending
    }

    public static func commands(matching query: String) -> [Command] {
        commands.filter { $0.matches(query) }
    }
}

struct HotkeysPane: View {
    @State private var query = ""

    private var commands: [HotkeyCatalog.Command] {
        HotkeyCatalog.commands(matching: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            if commands.isEmpty {
                ContentUnavailableView(
                    "No shortcuts found",
                    systemImage: "keyboard",
                    description: Text("Try a command name, menu, or key.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { offset, command in
                            commandRow(command)
                            if offset < commands.count - 1 {
                                Hairline()
                            }
                        }
                    }
                    .background(Palette.raisedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Palette.separator, lineWidth: 1)
                    }
                    .padding(.bottom, 20)
                }
                .accessibilityLabel("Keyboard shortcuts")
                .accessibilityValue("\(commands.count) shortcuts")
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func commandRow(_ command: HotkeyCatalog.Command) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.primaryText)
                Text(command.location)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 12)
            Text(command.keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.separator, lineWidth: 1)
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(command.title), \(command.keys), \(command.location)")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metrics.paneIconSize))
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
            TextField("Filter shortcuts", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.sidebarLabel)
                .accessibilityLabel("Filter keyboard shortcuts")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Metrics.paneIconSize))
                        .foregroundStyle(Palette.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Metrics.minimumPointerTarget)
        .background(Palette.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
