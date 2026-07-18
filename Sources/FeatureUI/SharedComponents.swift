import AppCore
import AppKit
import SwiftUI

/// The shared chrome for both workspace side panes. Keeping this opaque and app-owned avoids
/// AppKit resolving a leading navigation sidebar and a trailing inspector to visibly different
/// materials over the desktop, even when both request `.sidebar` vibrancy.
struct SidebarSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // Translucent, not opaque: the pane sits on system blur with a tint wash on top,
            // so in light mode it reads as chrome over the workspace instead of a gray slab
            // (apple-design §12 — material weight encodes hierarchy). The tint keeps both
            // panes resolving to the same hue over any background.
            Rectangle().fill(.thinMaterial).ignoresSafeArea()
            Palette.sidebarBackground.opacity(0.6).ignoresSafeArea()
            content()
        }
    }
}

/// A trailing counterpart to macOS's floating navigation sidebar. SwiftUI's `.inspector`
/// supplies only a flat column, so the inset and rounded panel geometry are explicit here.
struct FloatingSidebarSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        SidebarSurface(content: content)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.separator.opacity(0.5), lineWidth: 1)
            }
            // Soft ambient shadow — the old 0.22 black halo read as a dark ring against a
            // light editor.
            .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
    }
}

/// A soft fade from transparent into a blurred, tinted surface. Content scrolls visibly into
/// the blur instead of stopping at a rule — used where a hairline would be too hard an edge.
struct ProgressiveBlurFooter: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            // The tint must reach full content-background opacity at the bottom edge, or the
            // material's grey shows through and the footer reads lighter than the editor.
            LinearGradient(
                colors: [Palette.contentBackground.opacity(0), Palette.contentBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.85), location: 0.55),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A one-pixel rule in the design's separator color.
///
/// SwiftUI's `Divider` ignores `foregroundStyle`, so tinting one silently leaves the system
/// default in place — which reads as a hard black line against the workspace surfaces in dark
/// mode. Filling a rectangle is the only way to actually choose the color.
struct Hairline: View {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .accessibilityHidden(true)
    }
}

/// SPEC §7.1: empty, loading, and recovery states are SwiftUI.
/// SPEC §17: the icon is decorative; the label carries the meaning for VoiceOver.
public struct EmptyStateView: View {
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.primaryText)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: Metrics.minimumPointerTarget)
                    .nativeAccessibleButton(
                        actionTitle,
                        help: message,
                        action: { action() }
                    )
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(message)
    }
}

/// SPEC §19: an unreadable file or a failed derived feature keeps its surface usable and
/// explains itself. Text + glyph, never colour alone (SPEC §5.5).
public struct InlineDiagnosticView: View {
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("⚠").accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .nativeAccessibleButton(
                        actionTitle,
                        help: message,
                        action: { action() }
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.minimumPointerTarget)
        .background(Palette.raisedBackground)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.separator), alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Warning. \(message)")
    }
}

/// The status footer (SPEC §5.1 "sync/index status", §19 degraded-state backbone).
public struct StatusFooterView: View {
    private let status: IndexStatus
    private let onRecover: (() -> Void)?
    private let onCancel: (() -> Void)?

    public init(
        status: IndexStatus,
        onRecover: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.status = status
        self.onRecover = onRecover
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(status.glyph)
                .font(Typography.statusText)
                .accessibilityHidden(true)
            Text(status.text)
                .font(Typography.statusText)
                .foregroundStyle(status.needsAttention ? Palette.primaryText : Palette.tertiaryText)
                .lineLimit(2)
            Spacer(minLength: 4)
            if status.isBusy, let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.link)
                    .font(Typography.statusText)
                    .nativeAccessibleButton(
                        "Cancel indexing",
                        value: status.text,
                        help: "Keeps the previous usable derived index",
                        action: { onCancel() }
                    )
            } else if status.needsAttention, let onRecover {
                Button("Fix…", action: onRecover)
                    .buttonStyle(.link)
                    .font(Typography.statusText)
                    .nativeAccessibleButton(
                        "Fix vault problem",
                        value: status.text,
                        help: "Choose a vault folder to recover",
                        action: { onRecover() }
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: Metrics.minimumPointerTarget)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vault status")
        .accessibilityValue(status.text)
    }
}

/// SPEC §5.5 / §17: the save state pairs a glyph with text and exposes both to VoiceOver.
public struct SaveStateView: View {
    private let state: DocumentSaveState

    public init(state: DocumentSaveState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text(state.glyph).accessibilityHidden(true)
            Text(state.statusText)
        }
        .font(Typography.statusText)
        .foregroundStyle(Palette.tertiaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Document status")
        .accessibilityValue(state.statusText)
    }
}
