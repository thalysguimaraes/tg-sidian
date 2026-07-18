import Foundation

public protocol VaultServicing: Sendable {
    var vaultID: VaultID { get }
    func listMarkdownFiles() async throws -> [RelativePath]
    func read(_ path: RelativePath) async throws -> VaultFileSnapshot
    func exists(_ path: RelativePath) async throws -> Bool
    @discardableResult
    func atomicWrite(
        _ content: String,
        to path: RelativePath,
        expectedFingerprint: FileFingerprint?
    ) async throws -> VaultFileSnapshot
    func move(_ source: RelativePath, to destination: RelativePath) async throws
}

public protocol IndexQuerying: Sendable {
    func search(_ request: SearchRequest) async -> [SearchHit]
    func note(id: NoteID) async -> NoteSummary?
    func allNotes() async -> [NoteSummary]
    func connections() async -> [ResolvedConnection]
    func backlinks(to noteID: NoteID) async -> [Backlink]
}

public protocol GraphSourcing: Sendable {
    func graph(root: NoteID, depth: Int, maxNodes: Int, maxEdges: Int) async throws -> GraphSnapshot
    /// Every indexed note and resolved link, with no root and no depth bound.
    func vaultGraph(maxNodes: Int, maxEdges: Int) async throws -> GraphSnapshot
}

@MainActor
public protocol EditorSurface: AnyObject {
    var text: String { get }
    var selection: Range<Int> { get set }
    var isDirty: Bool { get }
    func replaceBuffer(_ text: String, preservingSelectionWhenPossible: Bool)
}

public enum PerformanceOperation: String, Hashable, Sendable, Codable {
    case launch = "launch.warm.interactive"
    case noteOpen = "note.open.rendered"
    case editorPaint = "editor.keystroke.paint"
    case save = "note.save.atomic"
    case parse = "markdown.parse"
    case incrementalIndex = "index.incremental.visible"
    case initialIndexProgress = "index.initial.progress"
    case initialIndexComplete = "index.initial.complete"
    case search = "search.firstResult.visible"
    case graph = "graph.layout.visible"
}

public protocol PerformanceInstrumenting: Sendable {
    func begin(_ operation: PerformanceOperation)
    func end(_ operation: PerformanceOperation)
    func event(_ operation: PerformanceOperation)
}

public struct NoopPerformanceInstrument: PerformanceInstrumenting {
    public init() {}
    public func begin(_ operation: PerformanceOperation) {}
    public func end(_ operation: PerformanceOperation) {}
    public func event(_ operation: PerformanceOperation) {}
}
