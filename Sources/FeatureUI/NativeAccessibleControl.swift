import AppKit
import SwiftUI

/// Shared invariant for every actionable control exposed by the workspace accessibility tree.
public enum AccessibilityControlContract {
    public static func hasUsableLabel(_ label: String) -> Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// SwiftUI's custom/plain buttons on macOS can expose an empty AXTitle even when they have an
/// accessibility label. This overlay uses a native, transparent NSButton so assistive clients
/// receive a stable title, value, help string, enabled state, and press action.
struct NativeAccessibleButtonModifier: ViewModifier {
    let title: String
    let value: String?
    let help: String?
    let isEnabled: Bool
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        // An overlay is sized from the content it covers, so the AX shim can never widen or
        // stretch the control. A ZStack sibling would union its size into the layout instead.
        content
            .accessibilityHidden(true)
            .overlay {
                NativeAccessibleButton(
                    title: title,
                    value: value,
                    help: help,
                    isEnabled: isEnabled,
                    action: action
                )
            }
    }
}

extension View {
    func nativeAccessibleButton(
        _ title: String,
        value: String? = nil,
        help: String? = nil,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        precondition(
            AccessibilityControlContract.hasUsableLabel(title),
            "Accessible buttons require a non-empty title"
        )
        return modifier(NativeAccessibleButtonModifier(
            title: title,
            value: value,
            help: help,
            isEnabled: isEnabled,
            action: action
        ))
    }
}

private struct NativeAccessibleButton: NSViewRepresentable {
    let title: String
    let value: String?
    let help: String?
    let isEnabled: Bool
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    /// Accessibility-only: assistive clients press it via AXPress (which does not route
    /// through `hitTest`), but the mouse must never land on it. The shim is an AppKit view
    /// hosted inside SwiftUI overlays, and in translated container hierarchies (the floating
    /// inspector) its frame can drift from the control it describes — a click-eating shim
    /// then routes clicks to a neighbouring control (the calendar bug: clicking "17" fired
    /// "July 18"). Real clicks belong to the SwiftUI button underneath.
    private final class AccessibilityOnlyButton: NSButton {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSButton {
        let button = AccessibilityOnlyButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
        button.isBordered = false
        button.isTransparent = true
        button.setButtonType(.momentaryPushIn)
        update(button, coordinator: context.coordinator)
        return button
    }

    /// The NSButton's title gives it an intrinsic width. Without this the shim would size itself
    /// from the AX label rather than the control it is describing.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ button: NSButton, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: NSButton, coordinator: Coordinator) {
        coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
        button.toolTip = help
        button.setAccessibilityTitle(title)
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(value)
        button.setAccessibilityHelp(help)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func press() {
            action()
        }
    }
}
