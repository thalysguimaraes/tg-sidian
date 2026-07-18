import AppCore
import AppKit
import ExtensionSDK
import SwiftUI

extension NSColor {
    /// A folder tint from a persisted 6-digit hex string; invalid input degrades to the
    /// secondary label color rather than crashing the graph.
    convenience init(folderHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(srgbRed: 0.62, green: 0.62, blue: 0.64, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Node tinting shared by the full graph and the inspector mini-map: an enabled extension may
/// supply a top-level folder tint, otherwise a stable hue derived from the folder name keeps
/// clusters legible without binding FeatureUI to a particular compatibility layer.
@MainActor
enum GraphNodeTint {
    static func provider(for session: VaultSessionModel) -> @MainActor (GraphNode) -> NSColor {
        var cache: [String: NSColor] = [:]
        return { node in
            let components = node.note.path.rawValue.split(separator: "/")
            // Root-level notes have no folder to take a color from.
            guard components.count > 1, let folder = components.first.map(String.init) else {
                return .secondaryLabelColor
            }
            if let cached = cache[folder] { return cached }
            let color: NSColor
            if let path = try? RelativePath(folder),
               let tint = session.treeDecoration(for: path)?.tint {
                color = NSColor(extensionColor: tint)
            } else {
                color = fallbackColor(forFolder: folder)
            }
            cache[folder] = color
            return color
        }
    }

    /// Deterministic, muted hue from the folder name — golden-angle spacing keeps adjacent
    /// folders visually distinct without a curated palette.
    static func fallbackColor(forFolder folder: String) -> NSColor {
        var hash: UInt64 = 1_099_511_628_211
        for byte in folder.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(hue: hue, saturation: 0.45, brightness: 0.78, alpha: 1)
    }
}

extension NSColor {
    convenience init(extensionColor color: ExtensionColor) {
        self.init(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.opacity
        )
    }
}

/// The whole-vault graph as a first-class center-region destination (Route.graph). SpriteKit
/// owns the canvas; SwiftUI owns the chrome: search, zoom, and the truncation caption.
struct GraphScreen: View {
    @Bindable var session: VaultSessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewportCommand: LocalGraphViewportCommand?
    @State private var focusedNodeID: NoteID?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.contentBackground.ignoresSafeArea()
            if let graph = session.graph, !graph.nodes.isEmpty {
                LocalGraphSpriteView(
                    graph: graph,
                    style: .full,
                    reduceMotion: reduceMotion,
                    command: viewportCommand,
                    nodeColor: GraphNodeTint.provider(for: session),
                    onFocus: { focusedNodeID = $0 },
                    onOpen: { id in Task { await session.openNote(id) } }
                )
                .accessibilityHidden(true)
                chrome(graph)
            } else {
                EmptyStateView(
                    title: "No graph yet",
                    message: "Link notes with [[wiki links]] to grow the vault graph."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vault graph")
    }

    private func chrome(_ graph: GraphSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                searchField(graph)
                Spacer(minLength: 12)
                controlCluster
            }
            if !matches(in: graph).isEmpty, searchFocused {
                searchResults(graph)
            }
            Spacer(minLength: 0)
            HStack {
                Text(summary(graph))
                    .font(Typography.statusText)
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityLabel("Graph size")
                    .accessibilityValue(summary(graph))
                Spacer()
            }
        }
        .padding(16)
    }

    private func searchField(_ graph: GraphSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
            TextField("Find note in graph", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { focusFirstMatch(graph) }
                .accessibilityLabel("Find note in graph")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiaryText)
                }
                .buttonStyle(.plain)
                .nativeAccessibleButton("Clear graph search", action: { query = "" })
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 260, height: 30)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private func searchResults(_ graph: GraphSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches(in: graph).prefix(8), id: \.note.id) { node in
                Button {
                    focus(node.note.id)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(nsColor: GraphNodeTint.provider(for: session)(node)))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(node.note.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(node.degree)")
                            .font(Typography.sidebarCount)
                            .foregroundStyle(Palette.tertiaryText)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nativeAccessibleButton(
                    node.note.title,
                    value: "\(node.degree) links",
                    help: "Centers the graph on this note",
                    action: { focus(node.note.id) }
                )
            }
        }
        .padding(.vertical, 6)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 1)
        }
        .accessibilityLabel("Graph search results")
    }

    private var controlCluster: some View {
        HStack(spacing: 2) {
            graphControl("minus.magnifyingglass", "Zoom out") {
                viewportCommand = LocalGraphViewportCommand(action: .zoomOut)
            }
            graphControl("plus.magnifyingglass", "Zoom in") {
                viewportCommand = LocalGraphViewportCommand(action: .zoomIn)
            }
            graphControl("arrow.down.right.and.arrow.up.left", "Fit graph") {
                viewportCommand = LocalGraphViewportCommand(action: .fit)
            }
            if session.currentNoteID != nil {
                graphControl("scope", "Center on current note") {
                    guard let current = session.currentNoteID else { return }
                    focus(current)
                }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private func graphControl(
        _ systemName: String,
        _ title: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .nativeAccessibleButton(title, action: action)
    }

    private func matches(in graph: GraphSnapshot) -> [GraphNode] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        return graph.nodes
            .filter { $0.note.title.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.degree > $1.degree }
    }

    private func focusFirstMatch(_ graph: GraphSnapshot) {
        guard let first = matches(in: graph).first else { return }
        focus(first.note.id)
    }

    private func focus(_ id: NoteID) {
        focusedNodeID = id
        searchFocused = false
        viewportCommand = LocalGraphViewportCommand(action: .focus(id))
    }

    private func summary(_ graph: GraphSnapshot) -> String {
        let notes = graph.nodes.count == 1 ? "1 note" : "\(graph.nodes.count) notes"
        let links = graph.edges.count == 1 ? "1 link" : "\(graph.edges.count) links"
        let truncation = graph.truncated ? " · showing most connected" : ""
        return "\(notes) · \(links)\(truncation)"
    }
}
