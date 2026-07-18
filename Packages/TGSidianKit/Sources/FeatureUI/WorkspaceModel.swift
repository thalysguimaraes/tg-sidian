import AppCore
import Foundation
import Observation

public enum WorkspaceStatus: Hashable, Sendable {
    case idle
    case indexing(completed: Int, total: Int?)
    case degraded(message: String)
    case conflict(path: RelativePath)
}

@Observable
@MainActor
public final class WorkspaceModel {
    public var preferences: AppPreferences
    public var selectedNoteID: NoteID?
    public var searchQuery: String
    public private(set) var searchResults: [SearchHit]
    public private(set) var isSearching: Bool
    public var status: WorkspaceStatus

    public init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        self.selectedNoteID = nil
        self.searchQuery = ""
        self.searchResults = []
        self.isSearching = false
        self.status = .idle
    }

    public func performSearch(using index: any IndexQuerying) async {
        isSearching = true
        defer { isSearching = false }
        searchResults = await index.search(SearchRequest(query: searchQuery))
    }

    public func select(_ noteID: NoteID?) {
        selectedNoteID = noteID
    }
}
