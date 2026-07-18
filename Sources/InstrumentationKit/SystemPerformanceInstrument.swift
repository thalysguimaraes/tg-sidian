import AppCore
import OSLog

public struct SystemPerformanceInstrument: PerformanceInstrumenting {
    private static let log = OSLog(subsystem: "com.tgsidian.app.performance", category: "domain")
    public let isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    public func begin(_ operation: PerformanceOperation) {
        guard isEnabled else { return }
        emit(.begin, operation)
    }

    public func end(_ operation: PerformanceOperation) {
        guard isEnabled else { return }
        emit(.end, operation)
    }

    public func event(_ operation: PerformanceOperation) {
        guard isEnabled else { return }
        emit(.event, operation)
    }

    private func emit(_ type: OSSignpostType, _ operation: PerformanceOperation) {
        switch operation {
        case .launch: os_signpost(type, log: Self.log, name: "launch.warm.interactive")
        case .noteOpen: os_signpost(type, log: Self.log, name: "note.open.rendered")
        case .editorPaint: os_signpost(type, log: Self.log, name: "editor.keystroke.paint")
        case .save: os_signpost(type, log: Self.log, name: "note.save.atomic")
        case .parse: os_signpost(type, log: Self.log, name: "markdown.parse")
        case .incrementalIndex: os_signpost(type, log: Self.log, name: "index.incremental.visible")
        case .initialIndexProgress: os_signpost(type, log: Self.log, name: "index.initial.progress")
        case .initialIndexComplete: os_signpost(type, log: Self.log, name: "index.initial.complete")
        case .search: os_signpost(type, log: Self.log, name: "search.firstResult.visible")
        case .graph: os_signpost(type, log: Self.log, name: "graph.layout.visible")
        }
    }
}
