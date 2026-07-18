import AppCore
import FeatureUI
import Foundation
import SwiftUI
import VaultKit

@main
struct EditorEngineHarnessApp: App {
    var body: some Scene {
        WindowGroup("tg-sidian Editor Engine Harness") {
            HarnessRootView()
                .frame(minWidth: 960, minHeight: 680)
        }
        .defaultSize(width: 1_080, height: 760)
    }
}

private struct HarnessRootView: View {
    @State private var context: HarnessContext?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let context {
                EditorHarnessView(context: context)
            } else if let loadError {
                ContentUnavailableView(
                    "Harness failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Creating isolated fixture…")
            }
        }
        .task {
            guard context == nil, loadError == nil else { return }
            do {
                context = try await HarnessContext.make()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct EditorHarnessView: View {
    let context: HarnessContext
    @State private var surface = NativeEditorSurfaceAdapter()
    @State private var status = "Ready — work through docs/manual-acceptance/PENTA-137.md"
    @State private var focusStatus = "not focused"
    @State private var operationInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            EditorHostView(
                document: context.document,
                fontSize: 15,
                lineWidth: 720,
                surface: surface,
                onFollowWikiLink: { target in
                    status = "Command-click resolved wiki target: \(target)"
                }
            )
            Divider()
            footer
        }
        .onAppear {
            surface.onFocusChange = { focused in
                focusStatus = focused ? "focused" : "not focused"
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Focus Editor") {
                    surface.requestFocus()
                    status = "SwiftUI requested AppKit first responder"
                }
                Button("External Replace") {
                    runReplacement(Self.externalSample, label: "external buffer")
                }
                Button("Load 1 MiB") {
                    runReplacement(Self.oneMiBNote, label: "1 MiB buffer")
                }
                Button("Reset Sample") {
                    runReplacement(Self.sample, label: "sample buffer")
                }
                Spacer()
                if operationInFlight { ProgressView().controlSize(.small) }
                Text("AppKit focus: \(focusStatus)")
                    .font(.caption.monospaced())
            }
            Text("Try a Japanese/Chinese IME composition, ⌘F, misspelling, Edit › Writing Tools, VoiceOver, undo/redo, selection, and a system appearance change. Command-click the wiki link; edit the task and fenced code as raw Markdown.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(context.document.state.statusText)
            Spacer()
            Text(status)
                .lineLimit(2)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func runReplacement(_ text: String, label: String) {
        operationInFlight = true
        status = "Loading \(label)…"
        Task {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                try await context.replaceBuffer(with: text)
                let elapsed = start.duration(to: clock.now)
                status = String(
                    format: "%@ loaded in %.2f ms; selection %@",
                    label,
                    Self.milliseconds(elapsed),
                    String(describing: surface.selection)
                )
            } catch {
                status = "Replacement failed: \(error.localizedDescription)"
            }
            operationInFlight = false
        }
    }

    fileprivate static let sample = """
    ---
    title: Editor engine harness
    tags: [penta-137, native]
    ---
    # Native Markdown editor validation

    Command-click [[Notes/Editor#Focus|this wiki link]].

    - [ ] Compose text with an IME
    - [ ] Open native Find with Command-F
    - [ ] Check spellcheck and Writing Tools

    ```swift
    let canonicalBuffer = "raw Markdown"
    ```

    Misspelled wrd for the spellcheck probe.
    """

    private static let externalSample = """
    # External replacement landed

    The model replaced the complete buffer while the adapter preserved a valid selection.
    Continue typing here, then use Undo and Redo.
    """

    private static let oneMiBNote: String = {
        let line = "- [ ] Validate [[Editor]] with `code`, IME prose, and Find text.\n"
        let target = 1_048_576
        let repeated = String(repeating: line, count: target / line.utf8.count + 1)
        return String(repeated.prefix(target))
    }()

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

@MainActor
private final class HarnessContext {
    let rootURL: URL
    let vault: VaultActor
    let path: RelativePath
    let document: EditorDocumentModel

    private init(
        rootURL: URL,
        vault: VaultActor,
        path: RelativePath,
        document: EditorDocumentModel
    ) {
        self.rootURL = rootURL
        self.vault = vault
        self.path = path
        self.document = document
    }

    static func make() async throws -> HarnessContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-editor-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = try RelativePath("Editor-Harness.md")
        try Data(EditorHarnessView.sample.utf8).write(
            to: root.appendingPathComponent(path.rawValue)
        )

        let vault = try VaultActor(rootURL: root)
        let journal = try RecoveryJournal(
            directory: root.appendingPathComponent(".recovery", isDirectory: true)
        )
        let document = EditorDocumentModel(
            vault: vault,
            saveCoordinator: SaveCoordinator(vault: vault, journal: journal)
        )
        document.open(try await vault.read(path))
        return HarnessContext(rootURL: root, vault: vault, path: path, document: document)
    }

    func replaceBuffer(with text: String) async throws {
        let snapshot = try await vault.atomicWrite(
            text,
            to: path,
            expectedFingerprint: document.savedFingerprint
        )
        document.open(snapshot)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
