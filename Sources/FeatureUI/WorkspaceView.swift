import AppCore
import SwiftUI

/// The sole tg-sidian artboard translated into a native three-region workspace.
public struct WorkspaceView: View {
    @Bindable private var session: VaultSessionModel
    @FocusState private var searchResultsFocused: Bool
    @State private var recoveryPresentation: RecoveryPresentation?
    private let onChangeVault: () -> Void

    public init(session: VaultSessionModel, onChangeVault: @escaping () -> Void) {
        self.session = session
        self.onChangeVault = onChangeVault
    }

    public var body: some View {
        // Native shell, mirroring tg-inspo: NavigationSplitView owns the sidebar (system
        // material, traffic-light integration, collapse behavior) and `.inspector` owns the
        // trailing pane. Custom chrome fought AppKit here; the platform does this for free.
        NavigationSplitView {
            SidebarSurface {
                SidebarView(session: session, onChangeVault: onChangeVault)
            }
                .navigationSplitViewColumnWidth(
                    min: WorkspaceSplitLayout.minimumSidebarWidth,
                    ideal: WorkspaceSplitLayout.sidebarWidth(session.sidebarWidth),
                    max: WorkspaceSplitLayout.maximumSidebarWidth
                )
                .background(WidthObserver { width in
                    session.setSplitWidths(sidebar: width, inspector: session.inspectorWidth)
                })
        } detail: {
            ZStack(alignment: .trailing) {
                centerRegion
                    .frame(minWidth: WorkspaceSplitLayout.minimumCenterWidth)

                if session.showsInspector {
                    FloatingSidebarSurface {
                        InspectorView(session: session, onCollapse: toggleInspector)
                    }
                    .frame(width: WorkspaceSplitLayout.inspectorPaneWidth)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 1_000, minHeight: 640)
        .background(Palette.contentBackground)
        .sheet(item: $recoveryPresentation) { presentation in
            RecoveryComparisonSheet(
                presentation: presentation,
                onRestore: {
                    recoveryPresentation = nil
                    Task {
                        if await session.document.restoreRecovery(presentation.record) {
                            await session.openNote(at: presentation.record.path)
                        }
                    }
                },
                onDismiss: {
                    recoveryPresentation = nil
                    Task { await session.document.discardRecovery(presentation.record) }
                }
            )
        }
    }

    /// Reports live column-width changes so drags persist to the per-vault workspace state.
    /// Only changes are reported — the initial layout pass must not clobber restored widths.
    private struct WidthObserver: View {
        let onChange: (Double) -> Void

        var body: some View {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width) { _, width in
                        guard width > 0 else { return }
                        onChange(width)
                    }
            }
        }
    }

    private var centerRegion: some View {
        VStack(spacing: 0) {
            editorToolbar
            Hairline()
            if let recovery = session.document.pendingRecoveryRecords.first {
                saveRecoveryBanner(recovery)
                Hairline()
            } else if let operation = session.recoverableFileOperations.last {
                fileOperationRecoveryBanner(operation)
                Hairline()
            } else if case let .writeFailed(message) = session.document.state {
                writeFailureBanner(message)
                Hairline()
            }
            switch session.route {
            case .empty:
                emptyEditor
            case .searchResults:
                searchResults
            case .note:
                EditorScreen(
                    session: session,
                    leadingChromeInset: editorChromeLeadingInset,
                    trailingChromeInset: editorChromeTrailingInset
                )
            case .graph:
                GraphScreen(session: session)
            }
        }
        .background(Palette.contentBackground)
    }

    private var editorToolbar: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: editorChromeLeadingInset)
                .accessibilityHidden(true)
            editorToolbarContent
                .frame(maxWidth: .infinity)
            Color.clear
                .frame(width: editorChromeTrailingInset)
                .accessibilityHidden(true)
        }
        .frame(height: Metrics.toolbarHeight)
        .background(Palette.contentBackground)
    }

    private var editorToolbarContent: some View {
        HStack(spacing: 8) {
            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoBack)
            .help("Back")
            .nativeAccessibleButton(
                "Back",
                help: "Return to the previous note or search",
                isEnabled: session.canGoBack,
                action: { session.goBack() }
            )

            Button {
                session.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!session.canGoForward)
            .help("Forward")
            .nativeAccessibleButton(
                "Forward",
                help: "Return to the next note or search",
                isEnabled: session.canGoForward,
                action: { session.goForward() }
            )

            if session.route == .graph {
                Text("Graph")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(Palette.raisedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else if let path = session.document.path {
                Text(path.nameWithoutExtension)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(Palette.raisedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Text("No note selected")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiaryText)
            }

            Spacer(minLength: 12)

            if !session.showsInspector {
                Button {
                    toggleInspector()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Show Inspector")
                .nativeAccessibleButton(
                    "Show inspector",
                    help: "Shows the calendar and graph sidebar",
                    action: { toggleInspector() }
                )
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    /// Floating content may extend beneath the inspector, but controls and metadata must stay
    /// inside the unobscured editor width.
    private var editorChromeLeadingInset: CGFloat {
        WorkspaceSplitLayout.sidebarWidth(session.sidebarWidth)
    }

    private var editorChromeTrailingInset: CGFloat {
        guard session.showsInspector else { return 0 }
        return WorkspaceSplitLayout.inspectorPaneWidth + 20
    }

    private func saveRecoveryBanner(_ record: RecoveryRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lifepreserver")
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recovered unsaved edits for \(record.path.lastComponent)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                Text("Compare them with the current disk version before restoring.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 8)
            Button("Compare…") {
                Task {
                    let comparison = await session.document.recoveryComparison(for: record)
                    recoveryPresentation = RecoveryPresentation(record: record, comparison: comparison)
                }
            }
            .nativeAccessibleButton(
                "Compare recovered edits",
                help: "Shows recovered and current disk versions",
                action: {
                    Task {
                        let comparison = await session.document.recoveryComparison(for: record)
                        recoveryPresentation = RecoveryPresentation(record: record, comparison: comparison)
                    }
                }
            )
            Button("Restore") {
                Task {
                    if await session.document.restoreRecovery(record) {
                        await session.openNote(at: record.path)
                    }
                }
            }
            .nativeAccessibleButton(
                "Restore recovered edits",
                help: "Atomically writes the recovered Markdown over the current disk revision",
                action: {
                    Task {
                        if await session.document.restoreRecovery(record) {
                            await session.openNote(at: record.path)
                        }
                    }
                }
            )
            Button("Dismiss") { Task { await session.document.discardRecovery(record) } }
                .nativeAccessibleButton(
                    "Dismiss recovered edits",
                    help: "Permanently removes this recovery record without changing the note",
                    action: { Task { await session.document.discardRecovery(record) } }
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.raisedBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recovered unsaved edits for \(record.path.lastComponent)")
    }

    private func fileOperationRecoveryBanner(_ record: FileOperationRecoveryRecord) -> some View {
        let message = switch record.operation {
        case .delete: "Deleted \(record.sourcePath.lastComponent) can be restored"
        case .move: "Moved \(record.sourcePath.lastComponent) can be undone"
        }
        return HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.primaryText)
            Spacer(minLength: 8)
            Button("Undo") { Task { await session.undoFileOperation(record) } }
                .nativeAccessibleButton(
                    "Undo file operation",
                    help: message,
                    action: { Task { await session.undoFileOperation(record) } }
                )
            Button("Dismiss") { Task { await session.dismissFileOperationRecovery(record) } }
                .nativeAccessibleButton(
                    "Dismiss file operation recovery",
                    help: "Keeps the operation and removes its recovery record",
                    action: { Task { await session.dismissFileOperationRecovery(record) } }
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.raisedBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }

    private func writeFailureBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Save failed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Retry") { Task { await session.document.retryFailedSave() } }
                .nativeAccessibleButton(
                    "Retry save",
                    help: "Retries the atomic save without discarding the buffer",
                    action: { Task { await session.document.retryFailedSave() } }
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.raisedBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Save failed. \(message)")
    }

    private var emptyEditor: some View {
        Group {
            if session.status.isBusy {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(session.status.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(session.status.text)
            } else if session.notes.isEmpty {
                EmptyStateView(
                    title: "This vault has no Markdown notes",
                    message: "Create a Markdown file in the vault or choose a different folder.",
                    actionTitle: "Choose Another Vault",
                    action: onChangeVault
                )
            } else {
                EmptyStateView(
                    title: "Choose a note",
                    message: "Select a Markdown note from the vault tree to start reading or writing."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleInspector() {
        withAnimation(Motion.collapse) {
            session.showsInspector.toggle()
        }
    }

    private var searchResults: some View {
        Group {
            if session.searchResults.isEmpty {
                EmptyStateView(
                    title: "No matching notes",
                    message: "Try a different title, path, tag, heading, or phrase."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(session.searchResults, id: \.note.id) { hit in
                                let selected = session.selectedSearchResultID == hit.note.id
                                Button {
                                    session.selectSearchResult(hit.note.id)
                                    Task { await session.openNote(at: hit.note.path) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(hit.note.title)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(Palette.primaryText)
                                            Spacer(minLength: 8)
                                            Text(resultMetadata(hit))
                                                .font(Typography.sidebarCount)
                                                .foregroundStyle(Palette.tertiaryText)
                                                .lineLimit(1)
                                        }
                                        Text(hit.note.path.rawValue)
                                            .font(Typography.monospacedMeta)
                                            .foregroundStyle(Palette.tertiaryText)
                                            .lineLimit(1)
                                        if !hit.excerpt.isEmpty {
                                            Text(hit.excerpt)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Palette.secondaryText)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(selected ? Palette.selectionFill : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .id(hit.note.id)
                                .buttonStyle(.plain)
                                .nativeAccessibleButton(
                                    hit.note.title,
                                    value: "\(hit.note.path.rawValue). \(resultMetadata(hit)). \(hit.excerpt)",
                                    help: "Opens this search result",
                                    action: { Task { await session.openNote(at: hit.note.path) } }
                                )
                                Hairline()
                            }
                        }
                    }
                    .onChange(of: session.selectedSearchResultID) {
                        if let id = session.selectedSearchResultID {
                            withAnimation(Motion.collapse) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                .focusable()
                .focused($searchResultsFocused)
                .onChange(of: session.searchResultsFocusRevision) {
                    searchResultsFocused = true
                }
                .onKeyPress(.downArrow) {
                    session.moveSearchSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    session.moveSearchSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.return) {
                    Task { await session.openSelectedSearchResult() }
                    return .handled
                }
                .accessibilityLabel("Search results")
                .accessibilityValue("\(session.searchResults.count) results")
            }
        }
        .background(Palette.contentBackground)
    }

    private func resultMetadata(_ hit: SearchHit) -> String {
        var values: [String] = []
        if let type = hit.note.type, !type.isEmpty { values.append(type) }
        values.append(contentsOf: hit.note.tags.sorted().prefix(3).map { "#\($0)" })
        values.append(hit.note.modifiedAt.formatted(date: .abbreviated, time: .omitted))
        return values.joined(separator: " · ")
    }
}

struct RecoveryPresentation: Identifiable {
    let record: RecoveryRecord
    let comparison: ConflictComparison
    var id: UUID { record.id }
}

struct RecoveryComparisonSheet: View {
    let presentation: RecoveryPresentation
    let onRestore: @MainActor @Sendable () -> Void
    let onDismiss: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recovered edits for \(presentation.record.path.lastComponent)")
                .font(.system(size: 15, weight: .semibold))
            Text(presentation.comparison.summary)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
            HStack(alignment: .top, spacing: 12) {
                side("Recovered edits", presentation.comparison.mine)
                side("Current disk version", presentation.comparison.theirs)
            }
            HStack {
                Button("Dismiss recovery", action: onDismiss)
                    .nativeAccessibleButton(
                        "Dismiss recovery",
                        help: "Keeps the disk version and removes the recovered edit",
                        action: onDismiss
                    )
                Spacer()
                Button("Restore recovered edits", action: onRestore)
                    .keyboardShortcut(.defaultAction)
                    .nativeAccessibleButton(
                        "Restore recovered edits",
                        help: "Atomically writes the recovered Markdown",
                        action: onRestore
                    )
            }
        }
        .padding(20)
        .frame(width: 760, height: 500)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recovery comparison")
    }

    private func side(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(Typography.monospacedMeta)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Palette.raisedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
