import AppCore
import SwiftUI

/// The editor region (SPEC §5.1): toolbar chrome, document editor, backlinks/status metadata.
public struct EditorScreen: View {
    @Bindable private var session: VaultSessionModel
    @State private var conflictComparison: ConflictComparison?
    private let leadingChromeInset: CGFloat
    private let trailingChromeInset: CGFloat

    public init(
        session: VaultSessionModel,
        leadingChromeInset: CGFloat = 0,
        trailingChromeInset: CGFloat = 0
    ) {
        self.session = session
        self.leadingChromeInset = leadingChromeInset
        self.trailingChromeInset = trailingChromeInset
    }

    public var body: some View {
        let dailyHeader = session.currentDailyNoteDate.flatMap(session.dailyNoteHeader(for:))
        return VStack(spacing: 0) {
            if session.document.state.isConflicted {
                conflictBanner
            }
            // The status bar floats over the editor on a progressive blur — prose scrolls
            // into the fade instead of stopping at a rule. The scroll view carries a matching
            // bottom content inset so the last lines can always scroll clear of the bar.
            //
            // The greedy frame must come BEFORE the overlay: the NSViewRepresentable reports
            // the document's transient fitting height, so anchoring to its own bounds (e.g.
            // via a bottom-aligned ZStack) drifts the bar into the middle of the viewport.
            // A max-infinity frame is always exactly the proposed size, so the overlay pins
            // to the real viewport bottom regardless of what the scroll view reports.
            // Enabled extensions may provide an in-document daily-note header that scrolls
            // with the prose rather than pinning above it.
            EditorHostView(
                document: session.document,
                fontSize: session.preferences.editorFontSize,
                lineWidth: session.preferences.editorLineWidth,
                spellcheckEnabled: session.preferences.spellcheckEnabled,
                header: dailyHeader,
                headerKey: session.currentDailyNoteDate.flatMap { date in
                    dailyHeader.map { _ in
                        "\(date.timeIntervalSinceReferenceDate)-\(session.extensionRegistry.revision)"
                    }
                },
                inlineTokenDecorationRevision: session.extensionRegistry.revision,
                inlineTokenDecorations: { text, excludedRanges in
                    session.inlineTokenDecorations(in: text, excluding: excludedRanges)
                },
                wikiLinkCompletions: { prefix in
                    session.wikiLinkCompletions(matching: prefix)
                },
                linkCompletionInsertion: { candidate in
                    session.linkInsertion(for: candidate)
                },
                templateInsertion: session.templateInsertion,
                onFollowWikiLink: { target in
                    Task { await session.followWikiLink(target) }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                statusBar
                    .background(alignment: .bottom) {
                        ProgressiveBlurFooter()
                            .frame(height: 56)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.contentBackground)
        .sheet(isPresented: Binding(
            get: { conflictComparison != nil },
            set: { if !$0 { conflictComparison = nil } }
        )) {
            if let comparison = conflictComparison {
                ConflictSheet(
                    comparison: comparison,
                    onResolve: { resolution in
                        conflictComparison = nil
                        Task { await session.document.resolveConflict(resolution) }
                    },
                    onMerge: { mergedText in
                        conflictComparison = nil
                        Task { await session.document.useMergedDraft(mergedText) }
                    }
                )
            }
        }
        .sheet(item: $session.pendingDisambiguation) { disambiguation in
            DisambiguationSheet(
                disambiguation: disambiguation,
                onPick: { summary in
                    session.pendingDisambiguation = nil
                    Task { await session.openNote(at: summary.path) }
                },
                onCancel: { session.pendingDisambiguation = nil }
            )
        }
        .sheet(item: $session.templatePicker) { picker in
            TemplatePickerSheet(
                choices: picker.choices,
                onPick: { path in Task { await session.insertTemplate(at: path) } },
                onCancel: { session.templatePicker = nil }
            )
        }
    }

    /// SPEC §9.3 / §19: a conflict blocks autosave and requires an explicit resolution. The
    /// banner is persistent rather than a transient alert, because the state persists.
    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Text("⚠").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("This note changed on disk")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
                Text("Autosave is paused so your edits are not overwritten.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 8)
            Button("Compare…") {
                Task { conflictComparison = await session.document.conflictComparison() }
            }
            .nativeAccessibleButton(
                "Compare conflict versions",
                help: "Shows your edits beside the version on disk",
                action: { Task { conflictComparison = await session.document.conflictComparison() } }
            )
            Button("Keep Mine") {
                Task { await session.document.resolveConflict(.keepMine) }
            }
            .nativeAccessibleButton(
                "Keep my edits",
                help: "Replaces the on-disk version with your edits",
                action: { Task { await session.document.resolveConflict(.keepMine) } }
            )
            Button("Reload") {
                Task { await session.document.resolveConflict(.reload) }
            }
            .nativeAccessibleButton(
                "Reload from disk",
                help: "Discards your local edits and reloads the on-disk version",
                action: { Task { await session.document.resolveConflict(.reload) } }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.minimumPointerTarget)
        .background(Palette.raisedBackground)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.separator), alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conflict. This note changed on disk. Autosave is paused.")
    }

    /// SPEC §9.1: line/column and word/character counts. Plus backlink count and save state.
    ///
    /// Backlinks and diagnostics are counts here rather than inspector sections. Diagnostics
    /// stay visible even at zero issues, so a note with invalid front matter or an unresolved
    /// wiki link reads as a changed count rather than failing silently (SPEC §13).
    private var statusBar: some View {
        let stats = session.document.statistics
        let issues = session.documentDiagnostics.count
        return HStack(spacing: 0) {
            Color.clear
                .frame(width: leadingChromeInset)
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                Text("\(session.backlinks.count) backlinks")
                    .font(Typography.statusText)
                    .foregroundStyle(Palette.tertiaryText)
                Text(issues == 1 ? "1 issue" : "\(issues) issues")
                    .font(Typography.statusText)
                    .foregroundStyle(issues > 0 ? Palette.secondaryText : Palette.tertiaryText)
                    .accessibilityLabel("Note diagnostics")
                    .accessibilityValue(issues == 1 ? "1 issue" : "\(issues) issues")
                SaveStateView(state: session.document.state)
                Spacer(minLength: 8)
                Text(stats.statusText)
                    .font(Typography.statusText)
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityLabel("Cursor and counts")
                    .accessibilityValue(stats.statusText)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: trailingChromeInset)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .frame(minHeight: 24)
        // The chrome-inset spacers are `Color.clear`, which accepts any proposed height. When
        // the overlay proposes the whole editor region, they would inflate the bar to full
        // height and center the text row mid-viewport. Hugging the content height keeps the
        // bar a bar.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TemplatePickerSheet: View {
    let choices: [TemplateChoice]
    let onPick: @MainActor @Sendable (RelativePath) -> Void
    let onCancel: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insert Template")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.primaryText)
            Text("Choose a Markdown file to insert at the cursor.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)

            templateList
                .padding(.top, 12)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .nativeAccessibleButton("Cancel template insertion", action: onCancel)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 400, height: 360)
        .background(Palette.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insert template")
    }

    private var templateList: some View {
        Group {
            if choices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Palette.tertiaryText)
                        .accessibilityHidden(true)
                    Text("No templates found")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.primaryText)
                    Text("Add Markdown files to the templates folder set in Settings > Files & Links.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { offset, choice in
                            templateRow(choice)
                            if offset < choices.count - 1 {
                                Hairline()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
    }

    private func templateRow(_ choice: TemplateChoice) -> some View {
        Button {
            onPick(choice.path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: Metrics.paneIconSize))
                    .frame(width: 16)
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityHidden(true)
                Text(choice.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(choice.path.rawValue)
                    .font(Typography.monospacedMeta)
                    .foregroundStyle(Palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Metrics.minimumPointerTarget + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nativeAccessibleButton(
            "Insert \(choice.title) template",
            help: choice.path.rawValue,
            action: { onPick(choice.path) }
        )
    }
}

/// SPEC §9.3: Compare shows both sides so the choice is informed (§22: no silent data loss).
struct ConflictSheet: View {
    let comparison: ConflictComparison
    let onResolve: (ConflictResolution) -> Void
    let onMerge: (String) -> Void
    @State private var mergedText: String

    init(
        comparison: ConflictComparison,
        onResolve: @escaping (ConflictResolution) -> Void,
        onMerge: @escaping (String) -> Void
    ) {
        self.comparison = comparison
        self.onResolve = onResolve
        self.onMerge = onMerge
        self._mergedText = State(initialValue: comparison.mergedDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This note changed on disk")
                .font(.system(size: 15, weight: .semibold))
            Text(comparison.summary)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
            if comparison.hasOverlappingChanges {
                Text("Both versions changed. Resolve the conflict markers in the merged draft before keeping it.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.primaryText)
            }

            HStack(alignment: .top, spacing: 12) {
                side(title: "Your edits", text: comparison.mine)
                side(title: "On disk", text: comparison.theirs)
            }
            .frame(height: 190)

            VStack(alignment: .leading, spacing: 6) {
                Text("Merged draft")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                TextEditor(text: $mergedText)
                    .font(Typography.monospacedMeta)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Palette.raisedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Editable merged draft")
            }

            HStack {
                Button("Reload from disk") { onResolve(.reload) }
                    .nativeAccessibleButton(
                        "Reload from disk",
                        help: "Discards your local edits",
                        action: { onResolve(.reload) }
                    )
                Spacer()
                Button("Keep my edits") { onResolve(.keepMine) }
                    .nativeAccessibleButton(
                        "Keep my edits",
                        help: "Writes your edits over the on-disk version",
                        action: { onResolve(.keepMine) }
                    )
                Button("Use merged draft") { onMerge(mergedText) }
                    .keyboardShortcut(.defaultAction)
                    .nativeAccessibleButton(
                        "Use merged draft",
                        help: "Saves the editable merged Markdown against the current disk revision",
                        action: { onMerge(mergedText) }
                    )
            }
        }
        .padding(20)
        .frame(width: 860, height: 620)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conflict resolution")
    }

    private func side(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// SPEC §6.3: ambiguous wiki links show a picker rather than silently choosing a target.
struct DisambiguationSheet: View {
    let disambiguation: LinkDisambiguation
    let onPick: (NoteSummary) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which note is [[\(disambiguation.rawTarget)]]?")
                .font(.system(size: 14, weight: .semibold))
            Text("Several notes match this link.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)

            List(disambiguation.candidates, id: \.id) { candidate in
                Button {
                    onPick(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.primaryText)
                        Text(candidate.path.rawValue)
                            .font(Typography.monospacedMeta)
                            .foregroundStyle(Palette.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: Metrics.minimumPointerTarget)
                .nativeAccessibleButton(
                    candidate.title,
                    value: candidate.path.rawValue,
                    help: "Opens this matching note",
                    action: { onPick(candidate) }
                )
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .nativeAccessibleButton(
                        "Cancel link selection",
                        action: { onCancel() }
                    )
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a link target")
    }
}
