import AppCore
import ExtensionSDK
import SwiftUI

/// The left vault sidebar (SPEC §5.1): vault switcher, search field, folder/note hierarchy with
/// counts and disclosure state, and the index/sync status footer.
public struct SidebarView: View {
    @Bindable private var session: VaultSessionModel
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.undoManager) private var undoManager
    @State private var operationPrompt: NoteOperationPrompt?
    @State private var operationValue = ""
    @State private var deleteTarget: RelativePath?
    @State private var showsSettings = false
    /// The folder whose icon/color the customize popover is editing, if any.
    @State private var appearanceTarget: SidebarNode?
    private let onChangeVault: () -> Void

    public init(session: VaultSessionModel, onChangeVault: @escaping () -> Void) {
        self.session = session
        self.onChangeVault = onChangeVault
    }

    public var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Metrics.paneTopPadding)
                .accessibilityHidden(true)
            vaultSwitcher
            searchField
            tree
            sidebarFooter
        }
        // No opaque background: the pane sits on WorkspaceSplitView's sidebar vibrancy
        // material, so the desktop blurs through like a native NavigationSplitView sidebar.
        .alert(
            operationPrompt?.title ?? "Edit Note",
            isPresented: Binding(
                get: { operationPrompt != nil },
                set: { if !$0 { operationPrompt = nil } }
            )
        ) {
            TextField(operationPrompt?.placeholder ?? "", text: $operationValue)
            Button("Cancel", role: .cancel) { operationPrompt = nil }
                .nativeAccessibleButton(
                    "Cancel file operation",
                    action: { operationPrompt = nil }
                )
            Button(operationPrompt?.actionTitle ?? "Apply") { submitOperationPrompt() }
                .nativeAccessibleButton(
                    operationPrompt?.actionTitle ?? "Apply file operation",
                    action: { submitOperationPrompt() }
                )
        } message: {
            Text(operationPrompt?.message ?? "")
        }
        .alert(
            "Delete Note?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { path in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
                .nativeAccessibleButton(
                    "Cancel delete",
                    action: { deleteTarget = nil }
                )
            Button("Delete", role: .destructive) { confirmDelete(path) }
                .nativeAccessibleButton(
                    "Delete \(path.lastComponent)",
                    help: "Removes the note with Undo and recovery available",
                    action: { confirmDelete(path) }
                )
        } message: { path in
            Text("\(path.lastComponent) will be removed from the vault. You can Undo or restore it from the recovery banner.")
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(session: session)
        }
        .sheet(item: $appearanceTarget) { node in
            FolderAppearancePicker(
                folderName: node.name,
                current: session.folderAppearance(node.id),
                onApply: { appearance in
                    session.setFolderAppearance(node.id, appearance)
                    appearanceTarget = nil
                },
                onCancel: { appearanceTarget = nil }
            )
        }
    }

    private var vaultSwitcher: some View {
        HStack(spacing: 4) {
            Button(action: onChangeVault) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(Typography.sidebarLabelSelected)
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: Metrics.paneDisclosureIconSize))
                        .foregroundStyle(Palette.tertiaryText)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Metrics.minimumPointerTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .nativeAccessibleButton(
                "Vault",
                value: session.displayName,
                help: "Choose a different vault folder",
                action: { onChangeVault() }
            )

            sortMenu
        }
        .padding(.horizontal, Metrics.paneHorizontalPadding)
    }

    /// Status and the single settings entry point share the footer: settings is a rarely-used
    /// destination, so it sits out of the vault switcher's way at the pane's bottom edge.
    private var sidebarFooter: some View {
        HStack(spacing: 4) {
            StatusFooterView(
                status: session.status,
                onRecover: onChangeVault,
                onCancel: { session.cancelIndexing() }
            )
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: Metrics.paneIconSize))
                    .foregroundStyle(Palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
            .help("Settings")
            .nativeAccessibleButton(
                "Settings",
                help: "Folder visibility, folder icons, and daily notes",
                action: { showsSettings = true }
            )
        }
        .padding(.trailing, Metrics.paneIconHorizontalPadding)
    }

    /// A Picker rather than a stack of Buttons: the native accessibility bridge overlays a
    /// transparent NSButton, which would swallow the clicks a menu item needs to receive.
    private var sortMenu: some View {
        Menu {
            Picker("Sort notes by", selection: $session.sidebarSortOrder) {
                ForEach(SidebarSortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: Metrics.paneIconSize))
                .foregroundStyle(Palette.tertiaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
        .help("Sort notes")
        .accessibilityLabel("Sort notes")
        .accessibilityValue(session.sidebarSortOrder.title)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metrics.paneIconSize))
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
            TextField("Search vault", text: Binding(
                get: { session.searchQuery },
                set: { session.search($0) }
            ))
            .textFieldStyle(.plain)
            .font(Typography.sidebarLabel)
            .focused($searchFieldFocused)
            .onChange(of: session.searchFocusRevision) {
                searchFieldFocused = true
            }
            .onKeyPress(.downArrow) {
                session.focusSearchResults()
                return .handled
            }
            .onSubmit {
                Task { await session.openSelectedSearchResult() }
            }
            .accessibilityLabel("Search vault")
            Text("⌘K")
                .font(Typography.sidebarCount)
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Metrics.minimumPointerTarget)
        .background(Palette.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, Metrics.paneHorizontalPadding)
        // The switcher and the field are separate controls, not a stacked pair: without this
        // the vault name sits directly on the field's top edge and reads as one block.
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if session.sidebar.isEmpty {
                    HStack(spacing: 8) {
                        if session.status.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text(session.status.isBusy ? "Indexing vault…" : "No Markdown files yet")
                            .font(Typography.sectionLabel)
                            .foregroundStyle(Palette.tertiaryText)
                    }
                    .padding(12)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(session.status.isBusy ? "Indexing vault" : "No Markdown files yet")
                } else {
                    ForEach(visibleRows) { entry in
                        row(entry.node, depth: entry.depth)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A node plus its indent level. The tree is flattened rather than rendered recursively:
    /// a recursive `some View` cannot type-check, and a flat list is what `LazyVStack` needs to
    /// stay lazy at 10k rows (SPEC §18).
    private struct VisibleRow: Identifiable {
        let node: SidebarNode
        let depth: Int
        var id: String { node.id }
    }

    private var visibleRows: [VisibleRow] {
        var result: [VisibleRow] = []
        func append(_ nodes: [SidebarNode], depth: Int) {
            for node in nodes {
                // A hidden folder drops out of the tree entirely, subtree and all; it stays
                // visible (and un-hideable) in Settings so it can always be brought back.
                if node.isFolder, session.isFolderHidden(node.id) { continue }
                result.append(VisibleRow(node: node, depth: depth))
                if node.isFolder, session.isFolderExpanded(node.id) {
                    append(node.children, depth: depth + 1)
                }
            }
        }
        append(session.sidebar, depth: 0)
        return result
    }

    private func row(_ node: SidebarNode, depth: Int) -> some View {
        let isExpanded = session.isFolderExpanded(node.id)
        let isSelected: Bool = {
            if case let .note(id) = node.kind, case let .note(current) = session.route {
                return id == current
            }
            return false
        }()

        return Button {
            activate(node)
        } label: {
            HStack(spacing: 6) {
                if node.isFolder {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: Metrics.paneDisclosureIconSize))
                        .frame(width: 10)
                        .foregroundStyle(Palette.tertiaryText)
                        .accessibilityHidden(true)
                } else {
                    Spacer().frame(width: 10)
                }
                folderOrNoteIcon(node)
                    .font(.system(size: Metrics.paneIconSize))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(node.name)
                    .font(isSelected ? Typography.sidebarLabelSelected : Typography.sidebarLabel)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if node.isFolder, node.noteCount > 0 {
                    Text("\(node.noteCount)")
                        .font(Typography.sidebarCount)
                        .foregroundStyle(Palette.tertiaryText)
                }
            }
            .padding(.leading, CGFloat(depth) * 12 + Metrics.paneHorizontalPadding)
            .padding(.trailing, Metrics.paneHorizontalPadding)
            .frame(minHeight: Metrics.sidebarRowMinHeight)
            .background(isSelected ? Palette.selectionFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nativeAccessibleButton(
            node.name,
            value: node.accessibilityValue(isExpanded: isExpanded) + (isSelected ? ", selected" : ""),
            help: accessibilityHint(for: node),
            action: { activate(node) }
        )
        .contextMenu {
            if let path = node.path, case .note = node.kind {
                Button("Rename…") { presentRename(path) }
                    .nativeAccessibleButton(
                        "Rename \(path.lastComponent)",
                        action: { presentRename(path) }
                    )
                Button("Move…") { presentMove(path) }
                    .nativeAccessibleButton(
                        "Move \(path.lastComponent)",
                        action: { presentMove(path) }
                    )
                Divider()
                Button("Delete…", role: .destructive) { deleteTarget = path }
                    .nativeAccessibleButton(
                        "Delete \(path.lastComponent)",
                        action: { deleteTarget = path }
                    )
            } else if node.isFolder {
                Button("Customize Icon…") { appearanceTarget = node }
                    .nativeAccessibleButton(
                        "Customize \(node.name) icon",
                        action: { appearanceTarget = node }
                    )
                if session.folderAppearance(node.id) != nil {
                    Button("Reset Icon") { session.setFolderAppearance(node.id, nil) }
                        .nativeAccessibleButton(
                            "Reset \(node.name) icon",
                            action: { session.setFolderAppearance(node.id, nil) }
                        )
                }
                Divider()
                Button("Hide Folder") { session.setFolderHidden(node.id, hidden: true) }
                    .nativeAccessibleButton(
                        "Hide \(node.name)",
                        help: "Removes the folder from the sidebar; it stays searchable",
                        action: { session.setFolderHidden(node.id, hidden: true) }
                    )
            }
        }
    }

    private func presentRename(_ path: RelativePath) {
        operationValue = path.nameWithoutExtension
        operationPrompt = NoteOperationPrompt(kind: .rename, path: path)
    }

    private func presentMove(_ path: RelativePath) {
        operationValue = path.deletingLastComponent?.rawValue ?? ""
        operationPrompt = NoteOperationPrompt(kind: .move, path: path)
    }

    private func submitOperationPrompt() {
        guard let prompt = operationPrompt else { return }
        operationPrompt = nil
        Task {
            switch prompt.kind {
            case .rename:
                await session.renameNote(
                    at: prompt.path,
                    to: operationValue,
                    undoManager: undoManager
                )
            case .move:
                let trimmed = operationValue.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    let folder = trimmed.isEmpty ? nil : try RelativePath(trimmed)
                    await session.moveNote(
                        at: prompt.path,
                        toFolder: folder,
                        undoManager: undoManager
                    )
                } catch {
                    session.reportFileOperationError("Move failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func confirmDelete(_ path: RelativePath) {
        deleteTarget = nil
        Task { await session.deleteNote(at: path, undoManager: undoManager) }
    }

    private func activate(_ node: SidebarNode) {
        switch node.kind {
        case .folder:
            session.toggleFolderExpansion(node.id)
        case .note:
            if let path = node.path {
                Task { await session.openNote(at: path) }
            }
        case .unreadable:
            if let path = node.path {
                session.reportUnreadableFile(path)
            }
        }
    }

    private func accessibilityHint(for node: SidebarNode) -> String {
        switch node.kind {
        case .folder: "Expands or collapses this folder"
        case .note: "Opens this Markdown note"
        case .unreadable: "Shows why this Markdown file could not be read"
        }
    }

    private func glyph(for node: SidebarNode) -> String {
        switch node.kind {
        case .folder: "folder"
        case .note: "doc.text"
        case .unreadable: "exclamationmark.triangle"
        }
    }

    /// A folder shows its app-owned icon/color when one is set; enabled extensions can then
    /// supply a neutral value-only decoration before the standard fallback is used.
    @ViewBuilder
    private func folderOrNoteIcon(_ node: SidebarNode) -> some View {
        if node.isFolder, let appearance = session.folderAppearance(node.id) {
            Image(systemName: appearance.symbolName)
                .foregroundStyle(Color(folderHex: appearance.colorHex))
        } else if let decoration = session.treeDecoration(for: node.path) {
            extensionIcon(
                decoration.icon,
                fallbackSystemName: glyph(for: node),
                size: Metrics.paneIconSize + 2
            )
            .foregroundStyle(
                decoration.tint.map(Color.init(extensionColor:)) ?? Palette.tertiaryText
            )
        } else {
            Image(systemName: glyph(for: node))
                .foregroundStyle(Palette.tertiaryText)
        }
    }

    @ViewBuilder
    private func extensionIcon(
        _ icon: ExtensionIcon?,
        fallbackSystemName: String,
        size: CGFloat
    ) -> some View {
        switch icon {
        case let .system(name):
            Image(systemName: name)
        case let .fontGlyph(glyph, fontName, fallback):
            if glyph.count == 1 {
                Text(glyph).font(.custom(fontName, fixedSize: size))
            } else {
                Image(systemName: fallback ?? fallbackSystemName)
            }
        case nil:
            Image(systemName: fallbackSystemName)
        }
    }
}

private extension Color {
    init(extensionColor color: ExtensionColor) {
        self.init(
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.opacity
        )
    }
}

private struct NoteOperationPrompt: Identifiable {
    enum Kind { case rename, move }
    let kind: Kind
    let path: RelativePath
    var id: String { "\(kind)-\(path.rawValue)" }
    var title: String { kind == .rename ? "Rename Note" : "Move Note" }
    var placeholder: String { kind == .rename ? "Note name" : "Folder path (blank for vault root)" }
    var actionTitle: String { kind == .rename ? "Rename" : "Move" }
    var message: String {
        kind == .rename
            ? "Enter a Markdown filename. The existing note is never overwritten."
            : "Enter a vault-relative folder. The existing destination is never overwritten."
    }
}
