import AppCore
import SwiftUI

/// The right inspector (SPEC §5.1): the contextual calendar and the graph.
///
/// Backlinks and diagnostics are not sections here. The design surfaces both as counts in the
/// editor status bar instead, where they stay visible without spending inspector height that
/// the calendar and graph need.
public struct InspectorView: View {
    @Bindable private var session: VaultSessionModel
    @State private var month: Date = Date()
    @State private var showsGraphOutline = false
    /// A day the user tapped that has no daily note yet, awaiting a create confirmation.
    @State private var pendingDailyNoteCreation: Date?
    private let onCollapse: @MainActor @Sendable () -> Void

    public init(
        session: VaultSessionModel,
        onCollapse: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.session = session
        self.onCollapse = onCollapse
        // Anchor the visible month to the wall-clock day: a raw Date() reads as next month
        // (in the configured UTC calendar) during the last evening hours of each month.
        _month = State(initialValue: session.dailyNoteConfiguration.canonicalToday())
    }

    public var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            CalendarView(
                month: $month,
                configuration: session.dailyNoteConfiguration,
                selectedDate: session.currentDailyNoteDate,
                onPick: selectDay
            )
            Spacer(minLength: 0)
            GraphSection(
                session: session,
                showsOutline: $showsGraphOutline
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // No opaque background: the pane sits on WorkspaceSplitView's sidebar vibrancy
        // material, matching the left sidebar's native treatment.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
        .confirmationDialog(
            pendingDailyNoteCreation.map { "Create a daily note for \(dailyNoteTitle(for: $0))?" } ?? "",
            isPresented: Binding(
                get: { pendingDailyNoteCreation != nil },
                set: { if !$0 { pendingDailyNoteCreation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let date = pendingDailyNoteCreation {
                Button("Create Daily Note") {
                    pendingDailyNoteCreation = nil
                    Task { await session.openDailyNote(for: date) }
                }
                .nativeAccessibleButton(
                    "Create daily note",
                    help: "Creates the daily note in the configured folder from your template",
                    action: {
                        pendingDailyNoteCreation = nil
                        Task { await session.openDailyNote(for: date) }
                    }
                )
                Button("Cancel", role: .cancel) { pendingDailyNoteCreation = nil }
                    .nativeAccessibleButton(
                        "Cancel daily note creation",
                        action: { pendingDailyNoteCreation = nil }
                    )
            }
        } message: {
            if pendingDailyNoteCreation != nil {
                Text("It will be created in \(session.dailyNoteConfiguration.folder.rawValue)/ from your template.")
                    .accessibilityLabel(
                        "Creates a daily note in \(session.dailyNoteConfiguration.folder.rawValue) from your template"
                    )
            }
        }
    }

    private var inspectorHeader: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onCollapse) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: Metrics.paneIconSize))
                    .foregroundStyle(Palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
            .help("Hide Inspector")
            .nativeAccessibleButton(
                "Hide inspector",
                help: "Collapses the calendar and graph sidebar",
                action: onCollapse
            )
        }
        .padding(.top, Metrics.paneTopPadding)
        .padding(.trailing, Metrics.paneIconHorizontalPadding)
    }

    /// Clicking a day opens its daily note. A day with no note yet asks first, then creates it in
    /// the configured folder from the template (SPEC §12.1) — the calendar never writes silently.
    private func selectDay(_ date: Date) {
        if dailyNoteExists(for: date) {
            Task { await session.openDailyNote(for: date) }
        } else {
            pendingDailyNoteCreation = date
        }
    }

    private func dailyNoteExists(for date: Date) -> Bool {
        guard let path = try? session.dailyNoteConfiguration.path(for: date) else { return false }
        return session.notes.contains { $0.path == path }
    }

    private func dailyNoteTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = session.dailyNoteConfiguration.calendar
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        return formatter.string(from: date)
    }
}

/// SPEC §12.1: the calendar opens or creates a date.
struct CalendarView: View {
    @Binding var month: Date
    let configuration: DailyNoteConfiguration
    let selectedDate: Date?
    let onPick: (Date) -> Void

    private var calendar: Calendar { configuration.calendar }

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdayRow
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.paneHorizontalPadding)
        .padding(.vertical, Metrics.paneTopPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(monthTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.primaryText)
            Spacer(minLength: 4)
            Button {
                month = shift(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: Metrics.paneIconSize))
                    .foregroundStyle(Palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
            .nativeAccessibleButton(
                "Previous month",
                help: "Shows the previous calendar month",
                action: { month = shift(by: -1) }
            )

            Button("TODAY") {
                let today = configuration.canonicalToday()
                month = today
                onPick(today)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.accent)
            .frame(minHeight: Metrics.minimumPointerTarget)
            .nativeAccessibleButton(
                "Go to today",
                help: "Opens or creates today's daily note",
                action: {
                    let today = configuration.canonicalToday()
                    month = today
                    onPick(today)
                }
            )

            Button {
                month = shift(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: Metrics.paneIconSize))
                    .foregroundStyle(Palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
            .nativeAccessibleButton(
                "Next month",
                help: "Shows the next calendar month",
                action: { month = shift(by: 1) }
            )
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(calendar.veryShortStandaloneWeekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    private func dayCell(_ day: Date?) -> some View {
        Group {
            if let day {
                let isToday = configuration.isCanonicalDateToday(day)
                let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                Button {
                    onPick(day)
                } label: {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(inMonth ? Palette.secondaryText : Palette.tertiaryText)
                        .frame(maxWidth: .infinity)
                        // SPEC §5.4: a minimum, not a fixed height — the cell grows with larger text.
                        .frame(minHeight: 26)
                        .background(isSelected || isToday ? Palette.selectionFill : Color.clear)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Palette.accent, lineWidth: 1)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nativeAccessibleButton(
                    accessibleDate(day),
                    value: isSelected ? "Selected daily note" : (isToday ? "Today" : nil),
                    help: "Opens or creates this daily note",
                    action: { onPick(day) }
                )
            } else {
                Color.clear.frame(maxWidth: .infinity).frame(minHeight: 26)
            }
        }
    }

    private func accessibleDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = configuration.calendar.locale
        formatter.timeZone = configuration.calendar.timeZone
        formatter.calendar = configuration.calendar
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = configuration.calendar.locale
        formatter.timeZone = configuration.calendar.timeZone
        formatter.calendar = configuration.calendar
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: month)
    }

    private func shift(by months: Int) -> Date {
        calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    /// Six weeks of optional days, so the grid height does not jump between months.
    private var weeks: [[Date?]] {
        guard
            let interval = calendar.dateInterval(of: .month, for: month),
            let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: interval.start)
        else { return [] }

        var days: [Date?] = []
        var cursor = firstWeek.start
        for _ in 0..<42 {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }
}

/// SPEC §9.4. SpriteKit owns the interactive spatial surface; a real, navigable outline exposes
/// the same visible nodes and edges for keyboard and VoiceOver users.
struct GraphSection: View {
    @Bindable var session: VaultSessionModel
    @Binding var showsOutline: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusedNodeID: NoteID?
    @State private var viewportCommand: LocalGraphViewportCommand?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let graph = session.graph, !graph.nodes.isEmpty {
                if showsOutline {
                    outline(graph)
                } else {
                    spriteGraph(graph)
                }
                controls(graph)
            } else {
                // SPEC §13: a derived feature explains its own degraded state; the editor stays usable.
                Text(session.graph == nil ? "Graph unavailable" : "No notes yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiaryText)
                    .padding(Metrics.paneHorizontalPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vault graph")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Graph")
                .font(Typography.sectionLabel)
                .foregroundStyle(Palette.tertiaryText)
            Spacer(minLength: 4)
            Button(showsOutline ? "Graph" : "Outline") {
                showsOutline.toggle()
            }
            .buttonStyle(.link)
            .font(.system(size: 10))
            .frame(minHeight: Metrics.minimumPointerTarget)
            .nativeAccessibleButton(
                showsOutline ? "Show interactive graph" : "Show connection outline",
                help: "The outline is a keyboard and VoiceOver equivalent of every visible graph connection",
                action: { showsOutline.toggle() }
            )
            Button {
                session.openGraph()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
            .help("Open the full graph")
            .nativeAccessibleButton(
                "Open full graph",
                help: "Shows the whole-vault graph in the editor area",
                action: { session.openGraph() }
            )
        }
        .padding(.horizontal, Metrics.paneHorizontalPadding)
        .padding(.top, Metrics.paneTopPadding)
    }

    private func spriteGraph(_ graph: GraphSnapshot) -> some View {
        LocalGraphSpriteView(
            graph: graph,
            style: .mini,
            reduceMotion: reduceMotion,
            command: viewportCommand,
            nodeColor: GraphNodeTint.provider(for: session),
            onFocus: { focusedNodeID = $0 },
            onOpen: { id in
                Task { await session.openNote(id) }
            }
        )
        .frame(height: 176)
        .padding(.horizontal, Metrics.paneHorizontalPadding)
        // The outline is the single semantic graph representation and avoids duplicate AX nodes.
        .accessibilityHidden(true)
    }

    private func outline(_ graph: GraphSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(graph.nodes.sorted(by: nodeSort), id: \.note.id) { node in
                    let connected = connectedNotes(to: node.note.id, in: graph)
                    Button {
                        Task { await session.openNote(at: node.note.path) }
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: node.note.id == session.currentNoteID ? "scope" : "circle.fill")
                                .font(.system(size: node.note.id == session.currentNoteID ? 10 : 5))
                                .foregroundStyle(Palette.tertiaryText)
                                .frame(width: 12, height: 14)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.note.title)
                                    .font(.system(size: 11, weight: node.note.id == session.currentNoteID ? .semibold : .regular))
                                    .foregroundStyle(Palette.secondaryText)
                                    .lineLimit(1)
                                Text(visibleConnectionSummary(connected))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.tertiaryText)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Text("\(connected.count)")
                                .font(Typography.sidebarCount)
                                .foregroundStyle(Palette.tertiaryText)
                        }
                        .padding(.horizontal, Metrics.paneHorizontalPadding)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minimumPointerTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .nativeAccessibleButton(
                        node.note.title,
                        value: accessibilityConnectionSummary(
                            node: node,
                            connected: connected,
                            root: session.currentNoteID
                        ),
                        help: "Opens this canonical Markdown note",
                        action: { Task { await session.openNote(at: node.note.path) } }
                    )
                }
            }
        }
        .frame(height: 176)
        .accessibilityLabel("Visible graph connections")
    }

    private func controls(_ graph: GraphSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                graphControl(
                    systemName: "minus.magnifyingglass",
                    title: "Zoom out graph",
                    help: "Shows more of the local graph"
                ) { viewportCommand = LocalGraphViewportCommand(action: .zoomOut) }
                graphControl(
                    systemName: "plus.magnifyingglass",
                    title: "Zoom in graph",
                    help: "Enlarges the local graph"
                ) { viewportCommand = LocalGraphViewportCommand(action: .zoomIn) }
                graphControl(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    title: "Fit graph",
                    help: "Fits every visible node in the graph viewport"
                ) { viewportCommand = LocalGraphViewportCommand(action: .fit) }
                graphControl(
                    systemName: "scope",
                    title: "Focus current note",
                    help: "Centers the graph on the current note"
                ) {
                    guard let current = session.currentNoteID else { return }
                    focusedNodeID = current
                    viewportCommand = LocalGraphViewportCommand(action: .focus(current))
                }
                Spacer(minLength: 2)
                Button {
                    if let focus = effectiveFocus(in: graph) {
                        Task { await session.openNote(focus) }
                    }
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: Metrics.paneIconSize))
                        .foregroundStyle(Palette.tertiaryText)
                }
                .buttonStyle(.plain)
                .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
                .disabled(effectiveFocus(in: graph) == nil)
                .nativeAccessibleButton(
                    "Open focused graph note",
                    value: focusedTitle(in: graph),
                    help: "Opens the focused node as canonical Markdown",
                    isEnabled: effectiveFocus(in: graph) != nil,
                    action: {
                        if let focus = effectiveFocus(in: graph) {
                            Task { await session.openNote(focus) }
                        }
                    }
                )
            }

            HStack(spacing: 8) {
                Text(nodeCountSummary(graph))
                    .font(Typography.statusText)
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityLabel("Graph size")
                    .accessibilityValue(nodeCountSummary(graph))
                Spacer(minLength: 4)
                if graph.truncated {
                    Text("Showing most connected")
                        .font(Typography.statusText)
                        .foregroundStyle(Palette.tertiaryText)
                        .accessibilityLabel("Graph truncated; showing the most connected notes")
                }
            }
        }
        .padding(.horizontal, Metrics.paneHorizontalPadding)
        .padding(.vertical, 4)
    }

    private func nodeCountSummary(_ graph: GraphSnapshot) -> String {
        let notes = graph.nodes.count == 1 ? "1 note" : "\(graph.nodes.count) notes"
        let links = graph.edges.count == 1 ? "1 link" : "\(graph.edges.count) links"
        return "\(notes) · \(links)"
    }

    private func graphControl(
        systemName: String,
        title: String,
        help: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Metrics.paneIconSize))
                .foregroundStyle(Palette.tertiaryText)
        }
        .buttonStyle(.plain)
        .frame(minWidth: Metrics.minimumPointerTarget, minHeight: Metrics.minimumPointerTarget)
        .nativeAccessibleButton(title, help: help, action: action)
    }

    /// The node the controls act on: whatever is focused, else the open note if it is on screen,
    /// else the first node. A vault graph has no root to fall back to.
    private func effectiveFocus(in graph: GraphSnapshot) -> NoteID? {
        if let focusedNodeID, graph.nodes.contains(where: { $0.note.id == focusedNodeID }) {
            return focusedNodeID
        }
        if let current = session.currentNoteID, graph.nodes.contains(where: { $0.note.id == current }) {
            return current
        }
        return graph.nodes.first?.note.id
    }

    private func focusedTitle(in graph: GraphSnapshot) -> String {
        let id = effectiveFocus(in: graph)
        return graph.nodes.first(where: { $0.note.id == id })?.note.title ?? "Current note"
    }

    private func connectedNotes(to id: NoteID, in graph: GraphSnapshot) -> [NoteSummary] {
        let connectedIDs = graph.edges.compactMap { edge -> NoteID? in
            if edge.source == id { return edge.target }
            if edge.target == id { return edge.source }
            return nil
        }
        let notesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.note.id, $0.note) })
        return connectedIDs.compactMap { notesByID[$0] }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func visibleConnectionSummary(_ notes: [NoteSummary]) -> String {
        guard !notes.isEmpty else { return "No visible connections" }
        let visible = notes.prefix(3).map(\.title).joined(separator: ", ")
        let remaining = notes.count - min(3, notes.count)
        return remaining > 0 ? "Connected to \(visible), and \(remaining) more" : "Connected to \(visible)"
    }

    private func accessibilityConnectionSummary(
        node: GraphNode,
        connected: [NoteSummary],
        root: NoteID?
    ) -> String {
        let prefix = node.note.id == root ? "Current note. " : ""
        guard !connected.isEmpty else { return prefix + "No visible connections" }
        return prefix + "Connected to " + connected.map(\.title).joined(separator: ", ")
    }

    private func nodeSort(_ lhs: GraphNode, _ rhs: GraphNode) -> Bool {
        if lhs.note.id == rhs.note.id { return false }
        if lhs.note.id == session.currentNoteID { return true }
        if rhs.note.id == session.currentNoteID { return false }
        return lhs.note.title.localizedStandardCompare(rhs.note.title) == .orderedAscending
    }
}
