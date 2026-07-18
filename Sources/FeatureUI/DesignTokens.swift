import AppKit
import SwiftUI

/// Semantic palette from SPEC §5.3. Call sites never use literals, so dark-mode and
/// Increase Contrast variants can be added here without touching views.
///
/// The three workspace surfaces carry their own values rather than sharing one chrome color:
/// the design separates sidebar, inspector, and editor by background alone, so collapsing any
/// two of them erases a boundary the design relies on.
public enum Palette {
    public static let windowBackground = dynamic(light: Reference.windowBackground, dark: Dark.windowBackground)
    public static let sidebarBackground = dynamic(light: Reference.sidebarBackground, dark: Dark.sidebarBackground)
    public static let inspectorBackground = dynamic(light: Reference.inspectorBackground, dark: Dark.inspectorBackground)
    public static let contentBackground = dynamic(light: Reference.contentBackground, dark: Dark.contentBackground)
    public static let raisedBackground = dynamic(light: Reference.raisedBackground, dark: Dark.raisedBackground)
    public static let separator = dynamic(light: Reference.separator, dark: Dark.separator)
    public static let selectionFill = Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
    public static let primaryText = Color(nsColor: .labelColor)
    public static let secondaryText = Color(nsColor: .secondaryLabelColor)
    public static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    public static let accent = Color(nsColor: .controlAccentColor)
    public static let link = Color(nsColor: .linkColor)

    /// Light-mode values, read from the design rather than transcribed by eye.
    public enum Reference {
        public static let windowBackground = "#EFEFF1"
        public static let sidebarBackground = "#EFEFF1"
        public static let inspectorBackground = "#F1F2F5"
        public static let contentBackground = "#FFFFFF"
        public static let raisedBackground = "#FFFFFF"
        public static let separator = "#DADCE2"
        public static let selectionFill = "#DCE5EF"
        public static let primaryText = "#2D2D33"
        public static let secondaryText = "#3D3D43"
        public static let tertiaryText = "#8E8E96"
        public static let accent = "#526B86"
        public static let link = "#58789A"
    }

    /// The design is light-only, so these are derived rather than specified. They preserve the
    /// light relationships with the figure/ground inverted: in light the editor is the lightest
    /// surface and the chrome recedes darker; in dark the editor is the darkest and the chrome
    /// lifts above it by the same order of separation.
    public enum Dark {
        public static let windowBackground = "#262628"
        public static let sidebarBackground = "#181818"
        public static let inspectorBackground = "#242427"
        public static let contentBackground = "#161616"
        public static let raisedBackground = "#2E2E31"
        public static let separator = "#3C3C40"
    }

    static func nativeColor(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: nativeColor(light: light, dark: dark))
    }
}

extension NSColor {
    /// Design values arrive as hex strings; an invalid literal is a programmer error, not a
    /// runtime condition to paper over with a fallback color.
    fileprivate convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        precondition(digits.count == 6, "Expected a 6-digit hex color, got \(hex)")
        guard let value = UInt32(digits, radix: 16) else {
            preconditionFailure("Expected a hex color, got \(hex)")
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Typography scale from SPEC §5.4. Sizes are minimums, never fixed frame heights:
/// rows grow with accessibility text sizes rather than clipping.
public enum Typography {
    public static let sidebarLabel = Font.system(size: 13, weight: .regular)
    public static let sidebarLabelSelected = Font.system(size: 13, weight: .medium)
    public static let sidebarCount = Font.system(size: 11, weight: .regular)
    public static let sectionLabel = Font.system(size: 12, weight: .regular)
    public static let editorTitle = Font.system(size: 30, weight: .bold)
    public static let statusText = Font.system(size: 11, weight: .regular)
    public static let monospacedMeta = Font.system(size: 11, weight: .regular, design: .monospaced)

    /// SPEC §5.4: editor body is user-configurable 14–20 pt, default 15 pt.
    public static func editorBody(size: Double) -> NSFont {
        NSFont.systemFont(ofSize: clampEditorFontSize(size))
    }

    public static func clampEditorFontSize(_ size: Double) -> Double {
        min(20, max(14, size))
    }

    /// SPEC §5.4: 1.55–1.65 leading.
    public static func editorLineHeightMultiple() -> Double { 1.6 }
}

/// SPEC §17: dense desktop pointer targets approximate 28×28 pt.
public enum Metrics {
    public static let minimumPointerTarget: CGFloat = 28

    /// Shared content insets for both side panes. The sidebar and inspector are separate view
    /// trees, so without a shared value their margins drift apart as either one is edited.
    /// Text starts at `paneHorizontalPadding`; icon-only controls use the smaller inset so a
    /// glyph centred in a 28 pt target still lands on the same optical margin as the text.
    public static let paneHorizontalPadding: CGFloat = 12
    public static let paneIconHorizontalPadding: CGFloat = 6
    public static let paneTopPadding: CGFloat = 8

    /// One size for every icon-only control in both panes, so a glyph reads the same weight
    /// wherever it appears. Disclosure triangles are the deliberate exception: they are row
    /// ornaments rather than controls, and at the control size they out-shout the note titles.
    public static let paneIconSize: CGFloat = 12
    public static let paneDisclosureIconSize: CGFloat = 10
    public static let sidebarRowMinHeight: CGFloat = 30
    public static let listRowMinHeight: CGFloat = 46
    public static let toolbarHeight: CGFloat = 52
    public static let sidebarDefaultWidth: CGFloat = 292
    public static let inspectorDefaultWidth: CGFloat = 292
}

/// SPEC §5.5: animations are interruptible and collapse to cross-fades under Reduce Motion.
public enum Motion {
    public static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var collapse: Animation {
        reduceMotionEnabled
            ? .easeInOut(duration: 0.12)
            : .interpolatingSpring(stiffness: 220, damping: 30)
    }
}
