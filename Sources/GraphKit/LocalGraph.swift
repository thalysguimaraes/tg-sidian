import AppCore
import Foundation
import IndexKit

public actor LocalGraphEngine: GraphSourcing {
    private let index: IndexActor
    private let layout: GraphLayoutActor
    private let instrument: any PerformanceInstrumenting

    public init(
        index: IndexActor,
        layout: GraphLayoutActor = GraphLayoutActor(),
        instrument: any PerformanceInstrumenting = NoopPerformanceInstrument()
    ) {
        self.index = index
        self.layout = layout
        self.instrument = instrument
    }

    /// The whole vault: every indexed note and every resolved link, with no root and no depth.
    ///
    /// The cap is a backstop for pathological vaults, not a view budget. Layout is all-pairs, so
    /// cost grows with the square of the node count; past the cap the most-connected notes are
    /// kept, because an arbitrary slice of a link graph is not a smaller link graph.
    public func vaultGraph(
        maxNodes: Int = 5_000,
        maxEdges: Int = 20_000
    ) async throws -> GraphSnapshot {
        instrument.begin(.graph)
        defer { instrument.end(.graph) }

        let summaries = await index.allNotes()
        let resolved = await index.connections().compactMap { connection -> GraphEdge? in
            guard connection.status == .resolved, let target = connection.target else { return nil }
            return GraphEdge(source: connection.source, target: target)
        }
        try Task.checkCancellation()

        var seenEdges: Set<UndirectedEdge> = []
        var undirected: [UndirectedEdge] = []
        for edge in resolved where edge.source != edge.target {
            let key = UndirectedEdge(edge.source, edge.target)
            guard seenEdges.insert(key).inserted else { continue }
            undirected.append(key)
        }

        var degrees: [NoteID: Int] = [:]
        for edge in undirected {
            degrees[edge.first, default: 0] += 1
            degrees[edge.second, default: 0] += 1
        }

        let boundedNodes = max(1, maxNodes)
        let boundedEdges = max(0, maxEdges)
        var truncated = false

        var retainedSummaries = summaries
        if retainedSummaries.count > boundedNodes {
            truncated = true
            retainedSummaries = retainedSummaries.sorted {
                let left = degrees[$0.id, default: 0]
                let right = degrees[$1.id, default: 0]
                return left == right ? $0.id < $1.id : left > right
            }
            retainedSummaries = Array(retainedSummaries.prefix(boundedNodes))
        }
        let retainedIDs = Set(retainedSummaries.map(\.id))

        var edges: [GraphEdge] = []
        for edge in undirected where retainedIDs.contains(edge.first) && retainedIDs.contains(edge.second) {
            guard edges.count < boundedEdges else {
                truncated = true
                break
            }
            edges.append(GraphEdge(source: edge.first, target: edge.second))
        }

        // Degree is recomputed over retained edges so a truncated graph never claims connections
        // to notes it is not showing.
        let visibleDegrees = edges.reduce(into: [NoteID: Int]()) { result, edge in
            result[edge.source, default: 0] += 1
            result[edge.target, default: 0] += 1
        }
        var nodes = retainedSummaries
            .map { GraphNode(note: $0, degree: visibleDegrees[$0.id, default: 0]) }
            .sorted { $0.note.id < $1.note.id }

        let positions = try await layout.layout(nodeIDs: nodes.map { $0.note.id }, edges: edges)
        for index in nodes.indices {
            nodes[index].position = positions[nodes[index].note.id] ?? GraphPoint(x: 0, y: 0)
        }
        return GraphSnapshot(root: nil, nodes: nodes, edges: edges, truncated: truncated)
    }

    public func graph(
        root: NoteID,
        depth: Int = 2,
        maxNodes: Int = 150,
        maxEdges: Int = 500
    ) async throws -> GraphSnapshot {
        instrument.begin(.graph)
        defer { instrument.end(.graph) }

        let summaries = await index.allNotes()
        guard summaries.contains(where: { $0.id == root }) else {
            throw TGSidianError.invalidOperation("Graph root is not indexed: \(root.rawValue)")
        }
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let resolved = await index.connections().compactMap { connection -> GraphEdge? in
            guard connection.status == .resolved, let target = connection.target else { return nil }
            return GraphEdge(source: connection.source, target: target)
        }

        var adjacency: [NoteID: Set<NoteID>] = [:]
        for edge in resolved {
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }

        let boundedDepth = max(0, min(4, depth))
        let boundedNodes = max(1, min(150, maxNodes))
        let boundedEdges = max(0, min(500, maxEdges))
        var visited: Set<NoteID> = [root]
        var queue: [(NoteID, Int)] = [(root, 0)]
        var cursor = 0
        var truncated = depth > boundedDepth || maxNodes > boundedNodes || maxEdges > boundedEdges

        while cursor < queue.count {
            try Task.checkCancellation()
            let (current, currentDepth) = queue[cursor]
            cursor += 1
            guard currentDepth < boundedDepth else { continue }

            for neighbor in (adjacency[current] ?? []).sorted() {
                guard !visited.contains(neighbor) else { continue }
                guard visited.count < boundedNodes else {
                    truncated = true
                    continue
                }
                visited.insert(neighbor)
                queue.append((neighbor, currentDepth + 1))
            }
        }

        var seenEdges: Set<UndirectedEdge> = []
        var edges: [GraphEdge] = []
        for edge in resolved where visited.contains(edge.source) && visited.contains(edge.target) {
            let key = UndirectedEdge(edge.source, edge.target)
            guard seenEdges.insert(key).inserted else { continue }
            guard edges.count < boundedEdges else {
                truncated = true
                break
            }
            edges.append(GraphEdge(source: key.first, target: key.second))
        }

        let degrees = edges.reduce(into: [NoteID: Int]()) { result, edge in
            result[edge.source, default: 0] += 1
            result[edge.target, default: 0] += 1
        }
        var nodes = visited.compactMap { id -> GraphNode? in
            guard let summary = summaryByID[id] else { return nil }
            return GraphNode(note: summary, degree: degrees[id, default: 0])
        }.sorted { $0.note.id < $1.note.id }

        let positions = try await layout.layout(nodeIDs: nodes.map { $0.note.id }, edges: edges)
        for index in nodes.indices {
            nodes[index].position = positions[nodes[index].note.id] ?? GraphPoint(x: 0, y: 0)
        }
        return GraphSnapshot(root: root, nodes: nodes, edges: edges, truncated: truncated)
    }
}

private struct UndirectedEdge: Hashable, Sendable {
    let first: NoteID
    let second: NoteID

    init(_ lhs: NoteID, _ rhs: NoteID) {
        if lhs < rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }
}

public actor GraphLayoutActor {
    private var snapshotCache: [LayoutKey: [NoteID: GraphPoint]] = [:]
    private var cacheOrder: [LayoutKey] = []
    private var stablePositions: [NoteID: GraphPoint] = [:]
    private let snapshotCacheLimit = 12

    public init() {}

    public func layout(
        nodeIDs: [NoteID],
        edges: [GraphEdge],
        iterations: Int = 40
    ) throws -> [NoteID: GraphPoint] {
        try Task.checkCancellation()
        guard !nodeIDs.isEmpty else { return [:] }
        let sortedIDs = nodeIDs.sorted()
        let key = LayoutKey(nodeIDs: sortedIDs, edges: edges)
        if let cached = snapshotCache[key] { return cached }

        // A changed depth/snapshot starts existing notes from their last committed positions. The
        // exact-snapshot cache prevents repeated requests from iterating the layout farther and
        // makes graph refreshes visually stable.
        //
        // The simulation runs over flat arrays indexed by position in `sortedIDs`, not over
        // dictionaries keyed by NoteID. Repulsion is all-pairs, so a NoteID hash in the inner loop
        // is paid ~n²/2 times per iteration and dominates everything else: at vault scale that is
        // the difference between a layout that takes a minute and one that takes under a second.
        // The forces themselves are unchanged.
        var xs = [Double](repeating: 0, count: sortedIDs.count)
        var ys = [Double](repeating: 0, count: sortedIDs.count)
        for index in sortedIDs.indices {
            let point = stablePositions[sortedIDs[index]] ?? initialPosition(sortedIDs[index])
            xs[index] = point.x
            ys[index] = point.y
        }

        var indexByID = [NoteID: Int](minimumCapacity: sortedIDs.count)
        for index in sortedIDs.indices { indexByID[sortedIDs[index]] = index }
        // Edges are resolved to indices once rather than re-looked-up every iteration.
        let springs: [(source: Int, target: Int)] = edges.compactMap { edge in
            guard let source = indexByID[edge.source], let target = indexByID[edge.target] else { return nil }
            return (source, target)
        }

        let springLength = 90.0
        // The position clamp scales with node count: a fixed box packs a whole-vault graph
        // into a dense grid whose boundary rows read as solid bands. √n keeps area per node
        // roughly constant, so small local graphs stay tight while big vaults spread out.
        let bound = max(500.0, 26.0 * Double(sortedIDs.count).squareRoot())
        var forceX = [Double](repeating: 0, count: sortedIDs.count)
        var forceY = [Double](repeating: 0, count: sortedIDs.count)

        for iteration in 0..<max(0, iterations) {
            try Task.checkCancellation()
            let temperature = max(0.08, 1.0 - Double(iteration) / Double(max(1, iterations)))
            for index in forceX.indices {
                forceX[index] = 0
                forceY[index] = 0
            }

            xs.withUnsafeMutableBufferPointer { px in
                ys.withUnsafeMutableBufferPointer { py in
                    forceX.withUnsafeMutableBufferPointer { fx in
                        forceY.withUnsafeMutableBufferPointer { fy in
                            for left in px.indices {
                                let leftX = px[left]
                                let leftY = py[left]
                                var accumulatedX = 0.0
                                var accumulatedY = 0.0
                                for right in (left + 1)..<px.count {
                                    var dx = leftX - px[right]
                                    var dy = leftY - py[right]
                                    let distanceSquared = max(25, dx * dx + dy * dy)
                                    let distance = distanceSquared.squareRoot()
                                    if distance == 0 {
                                        dx = 1
                                        dy = 0
                                    }
                                    let magnitude = 4_000 / distanceSquared
                                    let pushX = magnitude * dx / distance
                                    let pushY = magnitude * dy / distance
                                    accumulatedX += pushX
                                    accumulatedY += pushY
                                    fx[right] -= pushX
                                    fy[right] -= pushY
                                }
                                fx[left] += accumulatedX
                                fy[left] += accumulatedY
                            }

                            for spring in springs {
                                let dx = px[spring.target] - px[spring.source]
                                let dy = py[spring.target] - py[spring.source]
                                let distance = max(1, (dx * dx + dy * dy).squareRoot())
                                let magnitude = (distance - springLength) * 0.025
                                let pullX = magnitude * dx / distance
                                let pullY = magnitude * dy / distance
                                fx[spring.source] += pullX
                                fy[spring.source] += pullY
                                fx[spring.target] -= pullX
                                fy[spring.target] -= pullY
                            }

                            for index in px.indices {
                                var x = px[index]
                                var y = py[index]
                                x += (fx[index] - x * 0.002) * temperature
                                y += (fy[index] - y * 0.002) * temperature
                                px[index] = min(bound, max(-bound, x))
                                py[index] = min(bound, max(-bound, y))
                            }
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()

        var positions = [NoteID: GraphPoint](minimumCapacity: sortedIDs.count)
        for index in sortedIDs.indices {
            positions[sortedIDs[index]] = GraphPoint(x: xs[index], y: ys[index])
        }
        snapshotCache[key] = positions
        cacheOrder.append(key)
        stablePositions.merge(positions) { _, new in new }
        if cacheOrder.count > snapshotCacheLimit {
            snapshotCache[cacheOrder.removeFirst()] = nil
        }
        if stablePositions.count > 1_000 {
            let retained = Set(snapshotCache.values.flatMap { $0.keys })
            stablePositions = stablePositions.filter { retained.contains($0.key) }
        }
        return positions
    }

    private func initialPosition(_ id: NoteID) -> GraphPoint {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let fraction = Double(hash % 10_000) / 10_000
        let angle = fraction * 2 * Double.pi
        let radius = 70 + Double((hash >> 16) % 80)
        return GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private struct LayoutKey: Hashable, Sendable {
        let nodeIDs: [NoteID]
        let edges: [EdgeKey]

        init(nodeIDs: [NoteID], edges: [GraphEdge]) {
            self.nodeIDs = nodeIDs
            self.edges = edges.map(EdgeKey.init).sorted {
                if $0.first != $1.first { return $0.first < $1.first }
                return $0.second < $1.second
            }
        }
    }

    private struct EdgeKey: Hashable, Sendable {
        let first: NoteID
        let second: NoteID

        init(_ edge: GraphEdge) {
            if edge.source < edge.target {
                first = edge.source
                second = edge.target
            } else {
                first = edge.target
                second = edge.source
            }
        }
    }
}
