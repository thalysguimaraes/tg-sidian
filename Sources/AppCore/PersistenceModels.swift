import Foundation

public struct SaveConflict: Error, Hashable, Sendable, Codable {
    public let path: RelativePath
    public let expected: FileFingerprint?
    public let actual: FileFingerprint?
    public let attemptedContent: String

    public init(
        path: RelativePath,
        expected: FileFingerprint?,
        actual: FileFingerprint?,
        attemptedContent: String
    ) {
        self.path = path
        self.expected = expected
        self.actual = actual
        self.attemptedContent = attemptedContent
    }
}

public enum ConflictResolution: String, Hashable, Sendable, Codable {
    case compare
    case keepMine
    case reload
}

public struct RecoveryRecord: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let vaultID: VaultID
    public let path: RelativePath
    public let attemptedContent: String
    public let expectedFingerprint: FileFingerprint?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        vaultID: VaultID,
        path: RelativePath,
        attemptedContent: String,
        expectedFingerprint: FileFingerprint?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.vaultID = vaultID
        self.path = path
        self.attemptedContent = attemptedContent
        self.expectedFingerprint = expectedFingerprint
        self.createdAt = createdAt
    }
}

/// A recoverable filesystem operation. The journal stores the complete UTF-8 source before the
/// canonical file is moved or removed, so a crash can never make Undo depend on the derived index.
public enum FileRecoveryOperation: String, Hashable, Sendable, Codable {
    case move
    case delete
}

public struct FileOperationRecoveryRecord: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let vaultID: VaultID
    public let operation: FileRecoveryOperation
    public let sourcePath: RelativePath
    public let destinationPath: RelativePath?
    /// Non-Markdown sibling holding a deleted file until Undo is dismissed.
    public let stagedPath: RelativePath?
    public let content: String
    public let sourceFingerprint: FileFingerprint
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        vaultID: VaultID,
        operation: FileRecoveryOperation,
        sourcePath: RelativePath,
        destinationPath: RelativePath? = nil,
        stagedPath: RelativePath? = nil,
        content: String,
        sourceFingerprint: FileFingerprint,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.vaultID = vaultID
        self.operation = operation
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.stagedPath = stagedPath
        self.content = content
        self.sourceFingerprint = sourceFingerprint
        self.createdAt = createdAt
    }
}

public struct DailyNoteConfiguration: Hashable, Sendable, Codable {
    public var folder: RelativePath
    public var filenamePattern: String
    public var templatePath: RelativePath?
    public var localeIdentifier: String
    public var timeZoneIdentifier: String
    public var calendarIdentifier: String

    public init(
        folder: RelativePath,
        filenamePattern: String = "yyyy-MM-dd'.md'",
        templatePath: RelativePath? = nil,
        localeIdentifier: String = "en_US_POSIX",
        timeZoneIdentifier: String = "UTC",
        calendarIdentifier: String = "gregorian"
    ) {
        self.folder = folder
        self.filenamePattern = filenamePattern
        self.templatePath = templatePath
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
        self.calendarIdentifier = calendarIdentifier
    }

    public static var `default`: DailyNoteConfiguration {
        DailyNoteConfiguration(folder: .dailyNotesDirectory)
    }

    /// The configured calendar is shared by creation, parsing, and the inspector so a date never
    /// changes meaning between the calendar UI and the canonical vault path.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: Self.calendarIdentifier(named: calendarIdentifier))
        calendar.locale = Locale(identifier: localeIdentifier)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        return calendar
    }

    public func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = filenamePattern
        let candidate = formatter.string(from: date)
        let pathExtension = (candidate as NSString).pathExtension.lowercased()
        return ["md", "markdown"].contains(pathExtension) ? candidate : candidate + ".md"
    }

    public func path(for date: Date) throws -> RelativePath {
        try folder.appending(filename(for: date))
    }

    /// The canonical date (midnight in the configured calendar) for the user's current
    /// wall-clock day. "Today" is a human concept: it follows the local clock even though
    /// filenames are canonicalized to the configured (default UTC) calendar — feeding a raw
    /// `Date()` into that calendar shifts the day west of Greenwich every evening.
    public func canonicalToday(now: Date = Date(), local: Calendar = .current) -> Date {
        let parts = local.dateComponents([.year, .month, .day], from: now)
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        return calendar.date(from: components) ?? now
    }

    /// Whether a canonical daily-note date is the user's current wall-clock day.
    public func isCanonicalDateToday(_ date: Date, now: Date = Date(), local: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: canonicalToday(now: now, local: local))
    }

    public func date(fromFilename filename: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = filenamePattern
        formatter.isLenient = false
        if let date = formatter.date(from: filename) { return date }

        // Patterns without a literal Markdown extension are normalized during creation.
        let extensionless = (filename as NSString).deletingPathExtension
        return formatter.date(from: extensionless)
    }

    public func templateDateText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func calendarIdentifier(named value: String) -> Calendar.Identifier {
        switch value.lowercased() {
        case "buddhist": .buddhist
        case "chinese": .chinese
        case "coptic": .coptic
        case "ethiopic-amete-mihret": .ethiopicAmeteMihret
        case "ethiopic-amete-alem": .ethiopicAmeteAlem
        case "hebrew": .hebrew
        case "iso8601": .iso8601
        case "indian": .indian
        case "islamic": .islamic
        case "islamic-civil": .islamicCivil
        case "japanese": .japanese
        case "persian": .persian
        case "republic-of-china": .republicOfChina
        default: .gregorian
        }
    }
}

public struct GraphPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct GraphNode: Hashable, Sendable, Codable {
    public let note: NoteSummary
    public let degree: Int
    public var position: GraphPoint

    public init(note: NoteSummary, degree: Int, position: GraphPoint = GraphPoint(x: 0, y: 0)) {
        self.note = note
        self.degree = degree
        self.position = position
    }
}

public struct GraphEdge: Hashable, Sendable, Codable {
    public let source: NoteID
    public let target: NoteID

    public init(source: NoteID, target: NoteID) {
        self.source = source
        self.target = target
    }
}

public struct GraphSnapshot: Hashable, Sendable, Codable {
    /// The focused note, or nil for a whole-vault graph, which has no single origin.
    public let root: NoteID?
    public var nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let truncated: Bool

    public init(root: NoteID?, nodes: [GraphNode], edges: [GraphEdge], truncated: Bool) {
        self.root = root
        self.nodes = nodes
        self.edges = edges
        self.truncated = truncated
    }
}

/// Per-vault window state that is safe to persist outside the canonical Markdown vault.
/// Relative paths are used deliberately so this file never duplicates the vault's full path.
/// How notes are ordered within a folder. Folders themselves are always alphabetical, matching
/// the design, because a folder has no date to sort on.
public enum SidebarSortOrder: String, CaseIterable, Sendable, Codable {
    /// The design's order: date-named notes newest-first, everything else A-Z. A vault whose
    /// daily notes are named `2026-07-16` reads chronologically without the user configuring
    /// anything, while ordinary notes stay alphabetical.
    case dateAwareNewestFirst
    case nameAscending
    case nameDescending
    case modifiedNewestFirst
    case modifiedOldestFirst

    public static let `default` = SidebarSortOrder.dateAwareNewestFirst

    public var title: String {
        switch self {
        case .dateAwareNewestFirst: "Date-aware (newest first)"
        case .nameAscending: "Name (A to Z)"
        case .nameDescending: "Name (Z to A)"
        case .modifiedNewestFirst: "Modified (newest first)"
        case .modifiedOldestFirst: "Modified (oldest first)"
        }
    }
}

/// A folder's optional custom look in the sidebar: an SF Symbol name and an sRGB hex tint. SF
/// Symbols are Apple's own system set, so this stays fully native with no third-party asset
/// dependency. Both fields are validated on init so a corrupt preference can never crash a row.
public struct FolderAppearance: Hashable, Sendable, Codable {
    public let symbolName: String
    public let colorHex: String

    /// A conservative allowlist keeps a persisted string from ever asking AppKit for a symbol
    /// that does not exist; the sidebar picker only ever offers these. Every name here ships in
    /// SF Symbols 5, which is the set guaranteed on the macOS 14 deployment target.
    ///
    /// Ordered by theme — containers, documents, time, marks, work, study, money, making,
    /// nature, people, places, media, tech — so the picker's grid reads as groups when browsed
    /// without a search term.
    public static let symbolChoices: [String] = [
        // Containers
        "folder", "folder.fill", "tray.full", "archivebox", "shippingbox", "externaldrive",
        "internaldrive", "square.stack", "rectangle.stack",
        // Documents
        "doc.text", "doc.richtext", "doc.on.doc", "note.text", "text.book.closed",
        "list.bullet", "checklist", "newspaper", "scroll",
        // Time
        "calendar", "clock", "alarm", "hourglass", "timer",
        // Marks
        "star", "star.fill", "flag", "tag", "bookmark", "pin", "paperclip",
        "exclamationmark.triangle", "checkmark.seal",
        // Work
        "briefcase", "building.2", "chart.bar", "chart.pie", "target", "trophy",
        // Study
        "book", "book.closed", "graduationcap", "lightbulb", "brain", "magnifyingglass",
        "flask", "function",
        // Money
        "cart", "creditcard", "banknote", "dollarsign.circle", "giftcard",
        // Making
        "hammer", "wrench.and.screwdriver", "paintbrush", "paintpalette", "pencil.and.outline",
        "scissors", "cube",
        // Nature
        "leaf", "tree", "flame", "bolt", "drop", "snowflake", "sun.max", "moon", "cloud",
        "pawprint",
        // People
        "person", "person.2", "person.3", "heart", "hand.raised", "bubble.left", "envelope",
        "phone",
        // Places
        "globe", "map", "mappin", "house", "building.columns", "airplane", "car", "bicycle",
        // Media
        "camera", "photo", "film", "music.note", "headphones", "mic", "video", "paintbrush.pointed",
        // Tech
        "desktopcomputer", "laptopcomputer", "keyboard", "terminal", "chevron.left.forwardslash.chevron.right",
        "network", "lock", "key", "gearshape", "cpu", "antenna.radiowaves.left.and.right"
    ]

    public init(symbolName: String, colorHex: String) {
        self.symbolName = Self.symbolChoices.contains(symbolName) ? symbolName : "folder"
        // Normalize to a canonical `#RRGGBB` so a value stored with or without the leading hash,
        // in any case, round-trips to one stable string.
        self.colorHex = Self.normalizedHex(colorHex) ?? "#8E8E96"
    }

    public static func isValidHex(_ value: String) -> Bool {
        normalizedHex(value) != nil
    }

    static func normalizedHex(_ value: String) -> String? {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, UInt32(digits, radix: 16) != nil else { return nil }
        return "#" + digits.uppercased()
    }
}

public struct VaultWorkspaceState: Hashable, Sendable, Codable {
    public var sidebarWidth: Double
    public var inspectorWidth: Double
    public var showsInspector: Bool
    public var expandedFolderIDs: Set<String>
    public var lastOpenNotePath: RelativePath?
    public var dailyNoteConfiguration: DailyNoteConfiguration
    public var sidebarSortOrder: SidebarSortOrder
    /// Folder IDs hidden from the sidebar tree. Hiding is a view preference, never a filesystem
    /// change — the notes stay indexed, searchable, and linkable.
    public var hiddenFolderIDs: Set<String>
    /// Per-folder custom icon/color, keyed by folder ID.
    public var folderAppearances: [String: FolderAppearance]

    public init(
        sidebarWidth: Double = 292,
        inspectorWidth: Double = 292,
        showsInspector: Bool = true,
        expandedFolderIDs: Set<String> = [],
        lastOpenNotePath: RelativePath? = nil,
        dailyNoteConfiguration: DailyNoteConfiguration = .default,
        sidebarSortOrder: SidebarSortOrder = .default,
        hiddenFolderIDs: Set<String> = [],
        folderAppearances: [String: FolderAppearance] = [:]
    ) {
        self.sidebarWidth = min(420, max(220, sidebarWidth))
        self.inspectorWidth = min(360, max(250, inspectorWidth))
        self.showsInspector = showsInspector
        self.expandedFolderIDs = Set(expandedFolderIDs.filter { $0.hasPrefix("folder:") })
        self.lastOpenNotePath = lastOpenNotePath
        self.dailyNoteConfiguration = dailyNoteConfiguration
        self.sidebarSortOrder = sidebarSortOrder
        self.hiddenFolderIDs = Set(hiddenFolderIDs.filter { $0.hasPrefix("folder:") })
        self.folderAppearances = folderAppearances.filter { $0.key.hasPrefix("folder:") }
    }

    private enum CodingKeys: String, CodingKey {
        case sidebarWidth
        case inspectorWidth
        case showsInspector
        case expandedFolderIDs
        case lastOpenNotePath
        case dailyNoteConfiguration
        case sidebarSortOrder
        case hiddenFolderIDs
        case folderAppearances
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sidebarWidth: try values.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 292,
            inspectorWidth: try values.decodeIfPresent(Double.self, forKey: .inspectorWidth) ?? 292,
            showsInspector: try values.decodeIfPresent(Bool.self, forKey: .showsInspector) ?? true,
            expandedFolderIDs: try values.decodeIfPresent(Set<String>.self, forKey: .expandedFolderIDs) ?? [],
            lastOpenNotePath: try values.decodeIfPresent(RelativePath.self, forKey: .lastOpenNotePath),
            dailyNoteConfiguration: try values.decodeIfPresent(
                DailyNoteConfiguration.self,
                forKey: .dailyNoteConfiguration
            ) ?? .default,
            sidebarSortOrder: try values.decodeIfPresent(
                SidebarSortOrder.self,
                forKey: .sidebarSortOrder
            ) ?? .default,
            hiddenFolderIDs: try values.decodeIfPresent(Set<String>.self, forKey: .hiddenFolderIDs) ?? [],
            folderAppearances: try values.decodeIfPresent(
                [String: FolderAppearance].self,
                forKey: .folderAppearances
            ) ?? [:]
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sidebarWidth, forKey: .sidebarWidth)
        try values.encode(inspectorWidth, forKey: .inspectorWidth)
        try values.encode(showsInspector, forKey: .showsInspector)
        try values.encode(expandedFolderIDs, forKey: .expandedFolderIDs)
        try values.encodeIfPresent(lastOpenNotePath, forKey: .lastOpenNotePath)
        try values.encode(dailyNoteConfiguration, forKey: .dailyNoteConfiguration)
        try values.encode(sidebarSortOrder, forKey: .sidebarSortOrder)
        try values.encode(hiddenFolderIDs, forKey: .hiddenFolderIDs)
        try values.encode(folderAppearances, forKey: .folderAppearances)
    }
}

public protocol VaultWorkspaceStateStoring: Sendable {
    func load(vaultID: VaultID) -> VaultWorkspaceState
    func save(_ state: VaultWorkspaceState, vaultID: VaultID)
}
