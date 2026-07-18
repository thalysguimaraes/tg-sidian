import AppKit
import AppCore
import FeatureUI
import SecurityKit
import SwiftUI

@main
struct TGSidianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var launcher: VaultLaunchModel
    @State private var preferencesStore: AppPreferencesStore

    init() {
        let fileManager = FileManager.default
        let baseDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let applicationSupport = baseDirectory
            .appendingPathComponent("tg-sidian", isDirectory: true)
        let bookmarkDirectory = applicationSupport
            .appendingPathComponent("Bookmarks", isDirectory: true)
        let store: any VaultBookmarkStoring =
            (try? VaultBookmarkStore(directory: bookmarkDirectory)) ?? InMemoryBookmarkStore()

        let preferencesStore = AppPreferencesStore()
        _preferencesStore = State(initialValue: preferencesStore)
        _launcher = State(initialValue: VaultLaunchModel(
            bookmarkStore: store,
            applicationSupportDirectory: applicationSupport,
            preferencesStore: preferencesStore,
            extensionTypes: []
        ))
    }

    var body: some Scene {
        WindowGroup {
            LaunchRootView(
                launcher: launcher,
                onChooseVault: presentVaultPanel
            )
            .background(WindowConfigurationView())
            .preferredColorScheme(preferredColorScheme)
            .task {
                await launcher.restoreMostRecentVault()
            }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    guard let session = launcher.activeSession else { return }
                    Task { _ = await session.createNote(named: "Untitled") }
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(launcher.activeSession == nil)

                Button("Open Vault…", action: presentVaultPanel)
                    .keyboardShortcut("o", modifiers: [.command])
            }

            CommandMenu("Navigate") {
                Button("Search Vault") {
                    launcher.activeSession?.requestSearchFocus()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(launcher.activeSession == nil)

                Button("Toggle Inspector") {
                    launcher.activeSession?.showsInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(launcher.activeSession == nil)
            }

            CommandMenu("Markdown") {
                Button("Complete Wiki Link") {
                    NSApp.sendAction(#selector(NSTextView.complete(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.escape, modifiers: [.control])

                Button("Insert Template…") {
                    Task { await launcher.activeSession?.presentTemplatePicker() }
                }
                .disabled(launcher.activeSession == nil)

                Button("Toggle Task") {
                    NSApp.sendAction(#selector(MarkdownTextView.toggleMarkdownTask(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }

            CommandMenu("Vault") {
                Button("Rebuild Index") {
                    guard let session = launcher.activeSession else { return }
                    Task { await session.rebuildIndex() }
                }
                .disabled(launcher.activeSession == nil || launcher.activeSession?.status.isBusy == true)

                Button("Cancel Indexing") {
                    launcher.activeSession?.cancelIndexing()
                }
                .disabled(launcher.activeSession?.status.isBusy != true)
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferencesStore.preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    @MainActor
    private func presentVaultPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Obsidian Vault"
        panel.message = "Choose the folder that contains your Markdown notes."
        panel.prompt = "Open Vault"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await launcher.selectVault(url) }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct LaunchRootView: View {
    @Bindable var launcher: VaultLaunchModel
    let onChooseVault: () -> Void

    var body: some View {
        Group {
            switch launcher.state {
            case .needsVault:
                launchState(
                    title: "Open your Obsidian vault",
                    message: "tg-sidian reads and edits the Markdown files in a folder you choose.",
                    actionTitle: "Choose Vault…",
                    action: onChooseVault
                )
            case let .restoring(displayName):
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening \(displayName)…")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Opening vault \(displayName)")
            case let .permissionLost(_, reason):
                launchState(
                    title: "Vault access needs attention",
                    message: reason,
                    actionTitle: "Select Vault Again…",
                    action: onChooseVault
                )
            case let .failed(message):
                launchState(
                    title: "The vault could not be opened",
                    message: message,
                    actionTitle: "Choose Another Vault…",
                    action: onChooseVault
                )
            case let .ready(session):
                WorkspaceView(session: session, onChangeVault: onChooseVault)
            }
        }
        .frame(minWidth: 1_000, minHeight: 640)
        .background(Palette.contentBackground)
    }

    private func launchState(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        EmptyStateView(
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WindowConfigurationView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfiguringView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.setFrameAutosaveName("tg-sidian-main-window")
            window.title = "tg-sidian"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 1_000, height: 640)
        }
    }
}
