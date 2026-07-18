import Foundation

/// Width policy for the workspace columns. The shell itself is a native
/// `NavigationSplitView` + `.inspector` (see `WorkspaceView`), which owns the sidebar
/// material, traffic-light integration, and drag behavior; this enum keeps the numeric
/// policy — bounds and clamping for persisted per-vault widths — testable and in one place.
///
/// Both side panes are 292 in the design, but their ceilings differ because their content does.
/// The sidebar holds an arbitrarily deep folder tree, so width keeps buying legible paths. The
/// inspector's widest element is a fixed seven-column calendar that stops improving once the
/// columns are comfortable; past that it is just stretched. Neither pane should win width the
/// editor could use for prose, so the inspector is capped nearer its natural size.
public enum WorkspaceSplitLayout {
    public static let defaultSidebarWidth = 292.0
    public static let defaultInspectorWidth = 292.0
    public static let minimumSidebarWidth = 220.0
    public static let maximumSidebarWidth = 420.0
    public static let minimumCenterWidth = 520.0
    public static let minimumInspectorWidth = 250.0
    public static let maximumInspectorWidth = 360.0

    /// The rendered width of the floating inspector. The pane became a fixed overlay when the
    /// shell moved to a ZStack, so no drag can reach the persisted per-vault width any more;
    /// rendering that stale preference would let an old 360 stick with no way to undo it. The
    /// clamp above still governs decoding of persisted state, which is why it stays.
    public static let inspectorPaneWidth = 260.0

    public static func sidebarWidth(_ proposed: Double) -> Double {
        guard proposed.isFinite else { return defaultSidebarWidth }
        return min(maximumSidebarWidth, max(minimumSidebarWidth, proposed))
    }

    public static func inspectorWidth(_ proposed: Double) -> Double {
        guard proposed.isFinite else { return defaultInspectorWidth }
        return min(maximumInspectorWidth, max(minimumInspectorWidth, proposed))
    }

    public static func dividerPositions(
        totalWidth: Double,
        dividerThickness: Double,
        sidebarWidth proposedSidebarWidth: Double,
        inspectorWidth proposedInspectorWidth: Double,
        showsInspector: Bool
    ) -> (sidebar: Double, inspector: Double?) {
        let width = max(0, totalWidth)
        let thickness = max(0, dividerThickness)
        let inspector = inspectorWidth(proposedInspectorWidth)
        let inspectorReservation = showsInspector ? minimumInspectorWidth + thickness : 0
        let maximumSidebarForWindow = max(
            minimumSidebarWidth,
            width - minimumCenterWidth - inspectorReservation - thickness
        )
        let sidebar = min(sidebarWidth(proposedSidebarWidth), maximumSidebarForWindow)

        guard showsInspector else { return (sidebar, nil) }
        let maximumInspectorForWindow = max(
            minimumInspectorWidth,
            width - sidebar - minimumCenterWidth - thickness * 2
        )
        let usableInspector = min(inspector, maximumInspectorForWindow)
        return (sidebar, width - usableInspector - thickness)
    }
}
