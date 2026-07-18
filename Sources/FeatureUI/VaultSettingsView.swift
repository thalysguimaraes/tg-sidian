import AppCore
import ExtensionSDK
import SwiftUI

extension Color {
    /// A folder tint from a persisted 6-digit hex string. An invalid string degrades to the
    /// neutral tertiary color rather than crashing a sidebar row.
    init(folderHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = Palette.tertiaryText
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The vault settings window. App-wide preferences and vault-specific behavior share one
/// predictable source list, while each pane remains focused enough to scan at a glance.
struct SettingsView: View {
    @Bindable var session: VaultSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .general

    enum Section: String, CaseIterable, Identifiable {
        case general
        case editor
        case filesAndLinks
        case sidebar
        case dailyNotes
        case hotkeys
        case extensions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .editor: "Editor"
            case .filesAndLinks: "Files & Links"
            case .sidebar: "Sidebar"
            case .dailyNotes: "Daily Notes"
            case .hotkeys: "Hotkeys"
            case .extensions: "Extensions"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .editor: "text.cursor"
            case .filesAndLinks: "doc.badge.ellipsis"
            case .sidebar: "sidebar.left"
            case .dailyNotes: "calendar"
            case .hotkeys: "keyboard"
            case .extensions: "puzzlepiece.extension"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "Choose how tg-sidian looks on this Mac."
            case .editor: "Adjust the reading and writing experience."
            case .filesAndLinks: "Control where files are created and how links behave."
            case .sidebar: "Choose which folders appear. Hidden folders stay searchable and linkable."
            case .dailyNotes: "Where the calendar opens and creates a daily note, and how its filename is built."
            case .hotkeys: "Review and customize keyboard shortcuts."
            case .extensions: "Add optional capabilities to tg-sidian."
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sourceList
            Hairline(axis: .vertical)
            detail
        }
        .frame(width: 720, height: 520)
        .background(Palette.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 8)
                .accessibilityLabel("Vault \(session.displayName)")

            ForEach(Section.allCases) { item in
                sourceRow(item)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 8)
        .background(Palette.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private func sourceRow(_ item: Section) -> some View {
        let isSelected = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: Metrics.paneIconSize))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.tertiaryText)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Palette.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Metrics.minimumPointerTarget)
            .background(isSelected ? Palette.selectionFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nativeAccessibleButton(
            item.title,
            value: isSelected ? "selected" : nil,
            help: item.subtitle,
            action: { section = item }
        )
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                Text(section.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            switch section {
            case .general:
                generalPane
            case .editor:
                editorPane
            case .filesAndLinks:
                filesAndLinksPane
            case .sidebar:
                foldersPane
            case .dailyNotes:
                DailyNotesPane(
                    configuration: session.dailyNoteConfiguration,
                    onSave: { configuration in
                        Task { await session.updateDailyNoteConfiguration(configuration) }
                    }
                )
            case .hotkeys:
                HotkeysPane()
            case .extensions:
                extensionsPane
            }

            Hairline()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .nativeAccessibleButton("Done", help: "Closes settings", action: { dismiss() })
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var generalPane: some View {
        settingsForm {
            settingsGroup("Appearance") {
                settingsRow("Color scheme", detail: "Follow macOS, or keep the app light or dark.") {
                    Picker(
                        "Color scheme",
                        selection: Binding(
                            get: { session.preferences.appearance },
                            set: { session.preferences.appearance = $0 }
                        )
                    ) {
                        Text("System").tag(AppAppearance.system)
                        Text("Light").tag(AppAppearance.light)
                        Text("Dark").tag(AppAppearance.dark)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .accessibilityHint("Changes the app color scheme")
                }
            }
        }
        .accessibilityLabel("General settings")
    }

    /// The one row shape every pane shares: title and detail on the leading edge, the control
    /// trailing. Detail text lives here rather than under the control so rows scan as a column
    /// of settings instead of a form of captions.
    private func settingsRow(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.primaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control()
        }
    }

    private var editorPane: some View {
        settingsForm {
            settingsGroup("Typography") {
                valueSlider(
                    title: "Font size",
                    detail: "The text size used for note content.",
                    value: Binding(
                        get: { session.preferences.editorFontSize },
                        set: { session.preferences.editorFontSize = $0 }
                    ),
                    range: 12...24,
                    step: 1,
                    suffix: "pt"
                )

                Hairline()

                valueSlider(
                    title: "Readable line length",
                    detail: "Keeps long passages centered at a comfortable width.",
                    value: Binding(
                        get: { session.preferences.editorLineWidth },
                        set: { session.preferences.editorLineWidth = $0 }
                    ),
                    range: 480...960,
                    step: 40,
                    suffix: "pt"
                )
            }

            settingsGroup("Writing") {
                Toggle(
                    isOn: Binding(
                        get: { session.preferences.spellcheckEnabled },
                        set: { session.preferences.spellcheckEnabled = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Spellcheck")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.primaryText)
                        Text("Underline misspelled words as you type.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityHint("Turns continuous spellchecking in the note editor on or off")
            }
        }
        .accessibilityLabel("Editor settings")
    }

    private var filesAndLinksPane: some View {
        settingsForm {
            settingsGroup("New notes") {
                settingsRow("Default location", detail: "Where the New Note command creates notes.") {
                    Picker("Default location", selection: newNoteLocationBinding) {
                        Text("Vault root").tag(NewNoteLocationKind.vaultRoot)
                        Text("Same folder as current note").tag(NewNoteLocationKind.sameFolder)
                        Text("Chosen folder").tag(NewNoteLocationKind.chosenFolder)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .accessibilityHint("Controls where the New Note command creates notes")
                }

                if newNoteLocationKind == .chosenFolder {
                    Hairline()
                    settingsRow(
                        "Folder inside vault",
                        detail: "Created when you make the first note there."
                    ) {
                        TextField("Notes/Inbox", text: chosenNewNoteFolderBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                            .accessibilityLabel("Folder inside vault")
                            .accessibilityHint("Enter a relative folder such as Notes/Inbox")
                    }
                }
            }

            settingsGroup("Deleted notes") {
                settingsRow(
                    "Move deleted notes to",
                    detail: "Vault trash keeps the original folder structure in a hidden .trash folder and supports Undo."
                ) {
                    Picker("Move deleted notes to", selection: Binding(
                        get: { session.preferences.deletedNoteDestination },
                        set: { session.preferences.deletedNoteDestination = $0 }
                    )) {
                        Text("macOS Trash").tag(DeletedNoteDestination.macOSTrash)
                        Text("Vault .trash").tag(DeletedNoteDestination.vaultTrash)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .accessibilityHint("Chooses where deleted notes are moved")
                }
            }

            settingsGroup("Internal links") {
                settingsRow("Insert links as", detail: "How links to other notes are written into Markdown.") {
                    Picker("Insert links as", selection: Binding(
                        get: { session.preferences.internalLinkFormat },
                        set: { session.preferences.internalLinkFormat = $0 }
                    )) {
                        Text("Wiki links").tag(InternalLinkFormat.wikiLink)
                        Text("Markdown links").tag(InternalLinkFormat.markdown)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .accessibilityHint("Chooses the link syntax inserted into notes")
                }

                Hairline()

                Toggle(isOn: Binding(
                    get: { session.preferences.shortestLinkPaths },
                    set: { session.preferences.shortestLinkPaths = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shortest path when possible")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.primaryText)
                        Text("Links use the shortest name that is still unambiguous.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .accessibilityHint("Shortens inserted link paths when the note name is unique")
            }

            settingsGroup("Templates") {
                settingsRow(
                    "Templates folder",
                    detail: "Markdown > Insert Template places one at the cursor. Daily-note templates are configured separately."
                ) {
                    TextField("Templates", text: templatesFolderBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                        .accessibilityLabel("Templates folder")
                        .accessibilityHint("A relative vault folder containing Markdown templates")
                }
            }
        }
        .accessibilityLabel("Files and links settings")
    }

    private enum NewNoteLocationKind: Hashable {
        case vaultRoot
        case sameFolder
        case chosenFolder
    }

    private var newNoteLocationKind: NewNoteLocationKind {
        switch session.preferences.newNoteLocation {
        case .vaultRoot: .vaultRoot
        case .sameFolder: .sameFolder
        case .chosenFolder: .chosenFolder
        }
    }

    private var newNoteLocationBinding: Binding<NewNoteLocationKind> {
        Binding(
            get: { newNoteLocationKind },
            set: { kind in
                switch kind {
                case .vaultRoot: session.preferences.newNoteLocation = .vaultRoot
                case .sameFolder: session.preferences.newNoteLocation = .sameFolder
                case .chosenFolder:
                    let current = chosenNewNoteFolderBinding.wrappedValue
                    session.preferences.newNoteLocation = .chosenFolder(
                        (try? RelativePath(current)) ?? .dailyNotesDirectory
                    )
                }
            }
        )
    }

    private var chosenNewNoteFolderBinding: Binding<String> {
        Binding(
            get: {
                if case let .chosenFolder(folder) = session.preferences.newNoteLocation { return folder.rawValue }
                return ""
            },
            set: { value in
                guard let folder = try? RelativePath(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                session.preferences.newNoteLocation = .chosenFolder(folder)
            }
        )
    }

    private var templatesFolderBinding: Binding<String> {
        Binding(
            get: { session.preferences.templatesFolder?.rawValue ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                session.preferences.templatesFolder = trimmed.isEmpty ? nil : try? RelativePath(trimmed)
            }
        )
    }

    private func settingsForm(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingsGroup(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.tertiaryText)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .background(Palette.raisedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
        }
    }

    private func valueSlider(
        title: String,
        detail: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.primaryText)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 12)
            Slider(value: value, in: range, step: step)
                .frame(width: 130)
                .accessibilityLabel(title)
            Text("\(Int(value.wrappedValue)) \(suffix)")
                .font(Typography.monospacedMeta)
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 48, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private func placeholderPane(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.primaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private var extensionsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(session.extensionRegistry.manifests, id: \.id) { manifest in
                    extensionCard(manifest)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if session.extensionRegistry.manifests.isEmpty {
                placeholderPane(
                    symbol: "puzzlepiece.extension",
                    title: "No extensions installed",
                    message: "Optional capabilities installed with this build will appear here."
                )
            }
        }
        .accessibilityLabel("Extensions settings")
    }

    private func extensionCard(_ manifest: ExtensionManifest) -> some View {
        let enabled = session.extensionRegistry.isEnabled(manifest)
        let provider = session.extensionRegistry.enabledExtensions.first {
            type(of: $0).manifest.id == manifest.id
        } as? any SettingsPaneProviding

        return VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { session.extensionRegistry.isEnabled(manifest) },
                set: { session.extensionRegistry.setEnabled($0, for: manifest.id) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(manifest.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.primaryText)
                    Text(manifest.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .accessibilityHint(enabled ? "Disables this extension" : "Enables this extension")

            if !manifest.capabilities.isEmpty {
                HStack(spacing: 6) {
                    ForEach(manifest.capabilities.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
                        capability in
                        Text(capabilityLabel(capability))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Palette.selectionFill)
                            .clipShape(Capsule())
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Capabilities")
            }

            if enabled, let provider {
                Hairline()
                provider.settingsPane()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
    }

    private func capabilityLabel(_ capability: ExtensionCapability) -> String {
        switch capability {
        case .network: "Network"
        case .keychain: "Keychain"
        case .vaultRead: "Vault read"
        case .editorDecoration: "Editor decoration"
        }
    }

    private var foldersPane: some View {
        Group {
            if folderRows.isEmpty {
                VStack {
                    Text("This vault has no folders.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(folderRows.enumerated()), id: \.element.node.id) { offset, row in
                            folderToggle(row.node, depth: row.depth)
                            if offset < folderRows.count - 1 {
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
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderToggle(_ node: SidebarNode, depth: Int) -> some View {
        Toggle(isOn: Binding(
            get: { !session.isFolderHidden(node.id) },
            set: { visible in session.setFolderHidden(node.id, hidden: !visible) }
        )) {
            HStack(spacing: 8) {
                if let appearance = session.folderAppearance(node.id) {
                    Image(systemName: appearance.symbolName)
                        .font(.system(size: Metrics.paneIconSize))
                        .frame(width: 16)
                        .foregroundStyle(Color(folderHex: appearance.colorHex))
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: Metrics.paneIconSize))
                        .frame(width: 16)
                        .foregroundStyle(Palette.tertiaryText)
                }
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if node.noteCount > 0 {
                    Text("\(node.noteCount)")
                        .font(Typography.sidebarCount)
                        .foregroundStyle(Palette.tertiaryText)
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .frame(minHeight: Metrics.minimumPointerTarget + 4)
        .accessibilityLabel("\(node.name) visible")
    }

    /// Every folder in the vault, flattened with indent depth — including hidden ones, so this
    /// pane is the one place a hidden folder can always be brought back.
    private var folderRows: [(node: SidebarNode, depth: Int)] {
        var rows: [(SidebarNode, Int)] = []
        func walk(_ nodes: [SidebarNode], depth: Int) {
            for node in nodes where node.isFolder {
                rows.append((node, depth))
                walk(node.children, depth: depth + 1)
            }
        }
        walk(session.sidebar, depth: 0)
        return rows
    }
}

/// The daily-note form, inline in Settings rather than behind another sheet. It edits a local
/// copy and applies on Save, so a half-typed filename pattern never reaches the vault; the live
/// example path shows what the current fields resolve to before committing them.
struct DailyNotesPane: View {
    @State private var folder: String
    @State private var filenamePattern: String
    @State private var templatePath: String
    @State private var localeIdentifier: String
    @State private var timeZoneIdentifier: String
    @State private var calendarIdentifier: String
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    private let original: DailyNoteConfiguration
    let onSave: @MainActor (DailyNoteConfiguration) -> Void

    init(
        configuration: DailyNoteConfiguration,
        onSave: @escaping @MainActor (DailyNoteConfiguration) -> Void
    ) {
        original = configuration
        _folder = State(initialValue: configuration.folder.rawValue)
        _filenamePattern = State(initialValue: configuration.filenamePattern)
        _templatePath = State(initialValue: configuration.templatePath?.rawValue ?? "")
        _localeIdentifier = State(initialValue: configuration.localeIdentifier)
        _timeZoneIdentifier = State(initialValue: configuration.timeZoneIdentifier)
        _calendarIdentifier = State(initialValue: configuration.calendarIdentifier)
        self.onSave = onSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                fieldGroup("Location") {
                    field(
                        "Folder",
                        text: $folder,
                        prompt: "Daily Notes",
                        accessibility: "Daily note folder",
                        hint: "A vault-relative folder such as Daily Notes"
                    )
                    field(
                        "Filename",
                        text: $filenamePattern,
                        prompt: "yyyy-MM-dd'.md'",
                        accessibility: "Daily note filename pattern",
                        hint: "A Unicode date pattern; a Markdown extension is added when omitted"
                    )
                    field(
                        "Template",
                        text: $templatePath,
                        prompt: "Optional — Templates/Daily.md",
                        accessibility: "Daily note template path",
                        hint: "An optional vault-relative Markdown template"
                    )

                    Hairline()

                    examplePath
                }

                fieldGroup("Dates") {
                    field(
                        "Locale",
                        text: $localeIdentifier,
                        prompt: "en_US_POSIX",
                        accessibility: "Daily note locale"
                    )
                    field(
                        "Time zone",
                        text: $timeZoneIdentifier,
                        prompt: "UTC",
                        accessibility: "Daily note time zone",
                        hint: "An IANA identifier such as UTC or America/New_York"
                    )
                    field(
                        "Calendar",
                        text: $calendarIdentifier,
                        prompt: "gregorian",
                        accessibility: "Daily note calendar",
                        hint: "For example gregorian, iso8601, hebrew, or japanese"
                    )
                }

                if let errorMessage {
                    banner(errorMessage, symbol: "exclamationmark.triangle", tint: .red)
                } else if let savedMessage {
                    banner(savedMessage, symbol: "checkmark.circle", tint: Palette.accent)
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Revert") { revert() }
                        .disabled(!hasChanges)
                        .nativeAccessibleButton(
                            "Revert daily note settings",
                            help: "Restores the last saved values",
                            isEnabled: hasChanges,
                            action: { revert() }
                        )
                    Button("Save") { save() }
                        .disabled(!hasChanges)
                        .nativeAccessibleButton(
                            "Save daily note settings",
                            help: "Applies the daily-note folder, filename, template, locale, and time zone",
                            isEnabled: hasChanges,
                            action: { save() }
                        )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily note settings")
    }

    private func fieldGroup(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.tertiaryText)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .background(Palette.raisedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
        }
    }

    /// A leading label column keeps every field aligned on one axis, which is what the stacked
    /// full-width text fields were missing.
    private func field(
        _ label: String,
        text: Binding<String>,
        prompt: String,
        accessibility: String,
        hint: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 74, alignment: .trailing)
                .accessibilityHidden(true)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .accessibilityLabel(accessibility)
                .accessibilityHint(hint ?? "")
        }
    }

    /// The pattern is a date format, not a filename; showing what it resolves to today is the
    /// only way to tell a working pattern from a plausible-looking one before saving.
    private var examplePath: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Today")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 74, alignment: .trailing)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityHidden(true)
                Text(examplePathText)
                    .font(Typography.monospacedMeta)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Today's daily note resolves to \(examplePathText)")
            Spacer(minLength: 0)
        }
    }

    private var examplePathText: String {
        guard let configuration = try? draft() else { return "—" }
        return (try? configuration.path(for: Date()).rawValue) ?? "—"
    }

    private func banner(_ message: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: Metrics.paneIconSize))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var hasChanges: Bool {
        folder != original.folder.rawValue
            || filenamePattern != original.filenamePattern
            || templatePath != (original.templatePath?.rawValue ?? "")
            || localeIdentifier != original.localeIdentifier
            || timeZoneIdentifier != original.timeZoneIdentifier
            || calendarIdentifier != original.calendarIdentifier
    }

    private func revert() {
        folder = original.folder.rawValue
        filenamePattern = original.filenamePattern
        templatePath = original.templatePath?.rawValue ?? ""
        localeIdentifier = original.localeIdentifier
        timeZoneIdentifier = original.timeZoneIdentifier
        calendarIdentifier = original.calendarIdentifier
        errorMessage = nil
        savedMessage = nil
    }

    /// Builds a configuration from the current fields, throwing on anything the vault would
    /// reject. Shared by the live example and Save so they can never disagree.
    private func draft() throws -> DailyNoteConfiguration {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPattern = filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocale = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTimeZone = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCalendar = calendarIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else {
            throw TGSidianError.invalidOperation("Filename pattern cannot be empty.")
        }
        guard TimeZone(identifier: trimmedTimeZone) != nil else {
            throw TGSidianError.invalidOperation(
                "Time zone must be an IANA identifier such as UTC or America/New_York."
            )
        }
        let template = templatePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = DailyNoteConfiguration(
            folder: try RelativePath(trimmedFolder),
            filenamePattern: trimmedPattern,
            templatePath: template.isEmpty ? nil : try RelativePath(template),
            localeIdentifier: trimmedLocale.isEmpty ? "en_US_POSIX" : trimmedLocale,
            timeZoneIdentifier: trimmedTimeZone,
            calendarIdentifier: trimmedCalendar.isEmpty ? "gregorian" : trimmedCalendar
        )
        _ = try configuration.path(for: Date())
        return configuration
    }

    private func save() {
        do {
            let configuration = try draft()
            onSave(configuration)
            errorMessage = nil
            savedMessage = "Saved. The calendar now uses \(configuration.folder.rawValue)/."
        } catch {
            savedMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

/// Picks a folder's SF Symbol icon and tint. SF Symbols are Apple's own system set, so this needs
/// no third-party asset dependency and renders natively at any weight or size.
struct FolderAppearancePicker: View {
    let folderName: String
    let current: FolderAppearance?
    let onApply: (FolderAppearance) -> Void
    let onCancel: () -> Void

    @State private var symbolName: String
    @State private var colorHex: String
    @State private var symbolQuery = ""
    @FocusState private var searchFocused: Bool

    /// A legible palette derived from the app's own accent family plus common label colors, so
    /// custom folders still read as part of one design rather than a rainbow. Each entry is
    /// muted to roughly the same lightness, which is what keeps a tinted row from out-shouting
    /// the note title beside it.
    static let colorChoices: [String] = [
        "#8E8E96", "#7A6A58", "#526B86", "#58789A", "#3F7FA6", "#2E7D6B", "#4C8C4A",
        "#6E8F3A", "#B58A2E", "#C46A3F", "#B4514E", "#B0567F", "#8E5CA0", "#5B6BB5"
    ]

    init(
        folderName: String,
        current: FolderAppearance?,
        onApply: @escaping (FolderAppearance) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.folderName = folderName
        self.current = current
        self.onApply = onApply
        self.onCancel = onCancel
        _symbolName = State(initialValue: current?.symbolName ?? "folder")
        _colorHex = State(initialValue: current?.colorHex ?? Self.colorChoices[2])
    }

    /// Symbols whose name matches every whitespace-separated term. SF Symbol names are
    /// dot-separated paths (`person.2`, `doc.text`), so matching runs against a spaced form:
    /// that way "doc text" and "text" both find `doc.text` without a hand-kept keyword table
    /// drifting out of sync with the symbol list.
    private var filteredSymbols: [String] {
        let terms = symbolQuery
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return FolderAppearance.symbolChoices }
        return FolderAppearance.symbolChoices.filter { name in
            let haystack = name.replacingOccurrences(of: ".", with: " ")
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(folderHex: colorHex))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text("Customize \(folderName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
            }

            colorRow
            symbolSearchField
            symbolGrid

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .nativeAccessibleButton("Cancel", action: { onCancel() })
                Spacer()
                Button("Apply") {
                    onApply(FolderAppearance(symbolName: symbolName, colorHex: colorHex))
                }
                .keyboardShortcut(.defaultAction)
                .nativeAccessibleButton(
                    "Apply folder icon",
                    action: { onApply(FolderAppearance(symbolName: symbolName, colorHex: colorHex)) }
                )
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Palette.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Customize folder \(folderName)")
    }

    /// Swatches divide the line rather than sitting at a fixed pitch, so the row always spans the
    /// panel and adding a color reflows instead of overflowing the edge.
    private var colorRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.colorChoices, id: \.self) { hex in
                Button {
                    colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(folderHex: hex))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle().strokeBorder(
                                Palette.primaryText,
                                lineWidth: colorHex == hex ? 2 : 0
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.minimumPointerTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(hex)")
                .accessibilityAddTraits(colorHex == hex ? [.isSelected] : [])
            }
        }
    }

    private var symbolSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metrics.paneIconSize))
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
            TextField("Search icons", text: $symbolQuery)
                .textFieldStyle(.plain)
                .font(Typography.sidebarLabel)
                .focused($searchFocused)
                .accessibilityLabel("Search icons")
            if !symbolQuery.isEmpty {
                Button {
                    symbolQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Metrics.paneIconSize))
                        .foregroundStyle(Palette.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear icon search")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Metrics.minimumPointerTarget)
        .background(Palette.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// A fixed-height scroller: the symbol set is long enough that a self-sizing grid would grow
    /// the sheet past the screen, and a stable height keeps the Apply button in one place as the
    /// search narrows the results.
    private var symbolGrid: some View {
        ScrollView {
            let symbols = filteredSymbols
            if symbols.isEmpty {
                Text("No icons match “\(symbolQuery)”")
                    .font(Typography.sectionLabel)
                    .foregroundStyle(Palette.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 9),
                    spacing: 6
                ) {
                    ForEach(symbols, id: \.self) { name in
                        symbolCell(name)
                    }
                }
            }
        }
        .frame(height: 200)
    }

    private func symbolCell(_ name: String) -> some View {
        Button {
            symbolName = name
        } label: {
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(name == symbolName ? Color(folderHex: colorHex) : Palette.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(name == symbolName ? Palette.selectionFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("Icon \(name)")
        .accessibilityAddTraits(name == symbolName ? [.isSelected] : [])
    }
}
