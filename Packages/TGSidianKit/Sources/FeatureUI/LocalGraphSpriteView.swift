import AppCore
import AppKit
import SpriteKit
import SwiftUI

/// Camera clamps live outside the scene so they stay verifiable without a live SpriteKit view.
enum LocalGraphCamera {
    /// A camera scale below 1 magnifies the scene. Manual zoom may do that on request.
    static let minimumManualScale: CGFloat = 0.22
    static let maximumScale: CGFloat = 8

    /// Fitting only ever zooms out: a sparse graph renders at natural size rather than being
    /// magnified until its node labels dwarf the inspector.
    static func fitScale(contentSize: CGSize, viewSize: CGSize) -> CGFloat {
        let horizontal = contentSize.width / max(1, viewSize.width)
        let vertical = contentSize.height / max(1, viewSize.height)
        return min(maximumScale, max(1, max(horizontal, vertical)))
    }

    /// Label opacity for a camera scale: labels resolve in as the camera magnifies past the
    /// threshold, reaching full opacity at slightly more than half the threshold scale,
    /// instead of popping.
    static func labelAlpha(scale: CGFloat, threshold: CGFloat) -> CGFloat {
        guard threshold > 0, scale < threshold else { return 0 }
        let fullyVisibleAt = threshold * 0.55
        let t = (threshold - scale) / max(0.001, threshold - fullyVisibleAt)
        return min(1, max(0, t))
    }
}

struct LocalGraphViewportCommand: Equatable {
    enum Action: Equatable {
        case fit
        case zoomIn
        case zoomOut
        case focus(NoteID)
    }

    let id = UUID()
    let action: Action
}

/// How the graph surface is presented; the full pane earns hover labels and denser detail,
/// the inspector mini-map stays quiet.
enum GraphSurfaceStyle {
    case mini
    case full

    /// Camera scale below which every node label becomes visible. Fit scale is never below 1,
    /// so labels only resolve in once the user actually magnifies past the overview.
    var labelZoomThreshold: CGFloat {
        switch self {
        case .mini: 0 // never
        case .full: 0.9
        }
    }
}

/// Native SpriteKit graph surface. The adjacent SwiftUI outline is the semantic accessibility
/// surface; this view owns high-frequency pointer, camera, and render work without duplicating
/// inaccessible controls in the AX tree.
struct LocalGraphSpriteView: NSViewRepresentable {
    let graph: GraphSnapshot
    let style: GraphSurfaceStyle
    let reduceMotion: Bool
    let command: LocalGraphViewportCommand?
    /// Vault-aware node tint (folder color); called once per node per graph update.
    let nodeColor: @MainActor (GraphNode) -> NSColor
    let onFocus: @MainActor (NoteID) -> Void
    let onOpen: @MainActor (NoteID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SKView {
        let view = FocusableGraphSKView()
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 60
        view.allowsTransparency = true
        view.setAccessibilityElement(false)

        let scene = LocalGraphScene(size: CGSize(width: 260, height: 176))
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.style = style
        view.presentScene(scene)
        view.hoverScene = scene
        context.coordinator.scene = scene
        return view
    }

    func updateNSView(_ view: SKView, context: Context) {
        guard let scene = context.coordinator.scene else { return }
        scene.onFocus = onFocus
        scene.onOpen = onOpen
        scene.style = style
        scene.update(graph: graph, reduceMotion: reduceMotion, nodeColor: nodeColor)
        if let command, command.id != context.coordinator.lastCommandID {
            context.coordinator.lastCommandID = command.id
            scene.apply(command.action, reduceMotion: reduceMotion)
        }
    }

    final class Coordinator {
        fileprivate var scene: LocalGraphScene?
        var lastCommandID: UUID?
    }
}

private final class FocusableGraphSKView: SKView {
    weak var hoverScene: LocalGraphScene?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let scene = hoverScene else { return }
        scene.handleHover(at: event.location(in: scene))
    }

    override func mouseExited(with event: NSEvent) {
        hoverScene?.handleHover(at: nil)
    }
}

@MainActor
private final class LocalGraphScene: SKScene {
    var onFocus: ((NoteID) -> Void)?
    var onOpen: ((NoteID) -> Void)?
    var style: GraphSurfaceStyle = .mini

    private let graphContent = SKNode()
    private let graphCamera = SKCameraNode()
    private var graph: GraphSnapshot?
    private var nodeSprites: [NoteID: GraphNoteSprite] = [:]
    private var edgeSprites: [EdgeSprite] = []
    private var edgesByNode: [NoteID: [EdgeSprite]] = [:]
    private var neighbors: [NoteID: Set<NoteID>] = [:]
    private var focusedID: NoteID?
    private var hoveredID: NoteID?
    private var previousDragLocation: CGPoint?
    private var dragMoved = false
    private var hasFittedInitialGraph = false

    private struct EdgeSprite {
        let node: SKShapeNode
        let source: NoteID
        let target: NoteID
    }

    override init(size: CGSize) {
        super.init(size: size)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addChild(graphContent)
        addChild(graphCamera)
        camera = graphCamera
    }

    required init?(coder aDecoder: NSCoder) {
        nil
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard oldSize != size, graph != nil else { return }
        fit(animated: false)
    }

    func update(
        graph newGraph: GraphSnapshot,
        reduceMotion: Bool,
        nodeColor: (GraphNode) -> NSColor
    ) {
        guard graph != newGraph else { return }
        let previousPositions = nodeSprites.mapValues(\.position)
        graph = newGraph
        focusedID = newGraph.nodes.contains(where: { $0.note.id == focusedID })
            ? focusedID
            : newGraph.root
        hoveredID = nil

        graphContent.removeAllActions()
        graphContent.removeAllChildren()
        nodeSprites.removeAll(keepingCapacity: true)
        edgeSprites.removeAll(keepingCapacity: true)
        edgesByNode.removeAll(keepingCapacity: true)
        neighbors.removeAll(keepingCapacity: true)

        let finalPositions = Dictionary(uniqueKeysWithValues: newGraph.nodes.map {
            ($0.note.id, CGPoint(x: $0.position.x, y: -$0.position.y))
        })
        for edge in newGraph.edges {
            guard let source = finalPositions[edge.source], let target = finalPositions[edge.target] else {
                continue
            }
            let path = CGMutablePath()
            path.move(to: source)
            path.addLine(to: target)
            let line = SKShapeNode(path: path)
            line.strokeColor = .separatorColor
            line.lineWidth = 1
            line.alpha = 0.6
            line.zPosition = 0
            graphContent.addChild(line)
            let sprite = EdgeSprite(node: line, source: edge.source, target: edge.target)
            edgeSprites.append(sprite)
            edgesByNode[edge.source, default: []].append(sprite)
            edgesByNode[edge.target, default: []].append(sprite)
            neighbors[edge.source, default: []].insert(edge.target)
            neighbors[edge.target, default: []].insert(edge.source)
        }

        for node in newGraph.nodes {
            guard let target = finalPositions[node.note.id] else { continue }
            let sprite = GraphNoteSprite(
                noteID: node.note.id,
                title: node.note.title,
                radius: GraphNoteSprite.radius(forDegree: node.degree),
                color: nodeColor(node)
            )
            sprite.position = reduceMotion ? target : previousPositions[node.note.id] ?? target
            sprite.zPosition = 1
            nodeSprites[node.note.id] = sprite
            graphContent.addChild(sprite)
            if !reduceMotion, sprite.position != target {
                sprite.run(.move(to: target, duration: 0.22))
            }
        }
        updateNodeAppearance()

        if reduceMotion {
            // Reduce Motion preserves the context change but replaces node travel with a brief,
            // non-spatial opacity transition.
            graphContent.alpha = 0
            graphContent.run(.fadeIn(withDuration: 0.12))
        } else {
            graphContent.alpha = 1
        }
        if !hasFittedInitialGraph {
            hasFittedInitialGraph = true
            fit(animated: false)
        }
    }

    func apply(_ action: LocalGraphViewportCommand.Action, reduceMotion: Bool) {
        switch action {
        case .fit:
            fit(animated: !reduceMotion)
        case .zoomIn:
            zoom(by: 0.78)
        case .zoomOut:
            zoom(by: 1.28)
        case let .focus(id):
            focus(id, animated: !reduceMotion, notify: false)
        }
    }

    // MARK: - Pointer

    private var cursorPushed = false

    func handleHover(at location: CGPoint?) {
        let target = location.flatMap { graphNode(at: $0)?.noteID }
        guard target != hoveredID else { return }
        hoveredID = target
        updateNodeAppearance()
        if target != nil, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if target == nil, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        previousDragLocation = location
        dragMoved = false
        guard let sprite = graphNode(at: location) else { return }
        focus(sprite.noteID, animated: false, notify: true)
        if event.clickCount >= 2 { onOpen?(sprite.noteID) }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = event.location(in: self)
        defer { previousDragLocation = location }
        guard let previousDragLocation else { return }
        dragMoved = true
        graphCamera.position.x -= (location.x - previousDragLocation.x) * graphCamera.xScale
        graphCamera.position.y -= (location.y - previousDragLocation.y) * graphCamera.yScale
    }

    override func mouseUp(with event: NSEvent) {
        previousDragLocation = nil
    }

    override func scrollWheel(with event: NSEvent) {
        zoom(by: exp(Double(event.scrollingDeltaY) * 0.012))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 / max(0.2, 1 + event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            if let focusedID { onOpen?(focusedID) }
        case 123, 126: // Left / up
            moveKeyboardFocus(by: -1)
        case 124, 125: // Right / down
            moveKeyboardFocus(by: 1)
        case 3: // F
            if let focusedID { focus(focusedID, animated: false, notify: false) }
        default:
            super.keyDown(with: event)
        }
    }

    private func moveKeyboardFocus(by offset: Int) {
        guard let graph, !graph.nodes.isEmpty else { return }
        let ids = graph.nodes.map(\.note.id).sorted()
        let current = focusedID.flatMap(ids.firstIndex(of:)) ?? 0
        let next = min(ids.count - 1, max(0, current + offset))
        focus(ids[next], animated: false, notify: true)
    }

    private func graphNode(at location: CGPoint) -> GraphNoteSprite? {
        for node in nodes(at: location) {
            if let sprite = node as? GraphNoteSprite { return sprite }
            if let sprite = node.parent as? GraphNoteSprite { return sprite }
        }
        return nil
    }

    private func focus(_ id: NoteID, animated: Bool, notify: Bool) {
        guard let sprite = nodeSprites[id] else { return }
        focusedID = id
        updateNodeAppearance()
        let move = SKAction.move(to: sprite.position, duration: animated ? 0.2 : 0)
        move.timingMode = .easeInEaseOut
        graphCamera.run(move, withKey: "focus")
        if notify { onFocus?(id) }
    }

    // MARK: - Appearance

    /// One pass owns every node/edge visual so hover, focus, and zoom changes cannot disagree:
    /// hover highlights a neighborhood and quiets the rest; zoom fades labels in for the full
    /// surface; the root/current note keeps its accent.
    private func updateNodeAppearance() {
        guard let graph else { return }
        let hovered = hoveredID
        let hoverNeighbors = hovered.flatMap { neighbors[$0] } ?? []
        let zoomAlpha = LocalGraphCamera.labelAlpha(
            scale: graphCamera.xScale,
            threshold: style.labelZoomThreshold
        )

        for (id, sprite) in nodeSprites {
            let isRoot = id == graph.root
            let isFocused = id == focusedID
            let isHovered = id == hovered
            let inNeighborhood = hovered == nil || isHovered || hoverNeighbors.contains(id)

            sprite.setHighlighted(isRoot: isRoot, focused: isFocused, hovered: isHovered)
            sprite.alpha = inNeighborhood ? 1 : 0.18

            let labelAlpha: CGFloat = if isHovered || isFocused || isRoot {
                1
            } else if hovered != nil && hoverNeighbors.contains(id) {
                max(zoomAlpha, 0.85)
            } else if hovered != nil {
                0
            } else {
                zoomAlpha
            }
            sprite.setLabelAlpha(labelAlpha)
        }

        let incident = hovered.flatMap { hoveredID -> Set<ObjectIdentifier>? in
            guard let edges = edgesByNode[hoveredID] else { return [] }
            return Set(edges.map { ObjectIdentifier($0.node) })
        }
        for edge in edgeSprites {
            if let incident {
                let isIncident = incident.contains(ObjectIdentifier(edge.node))
                edge.node.strokeColor = isIncident ? .controlAccentColor : .separatorColor
                edge.node.alpha = isIncident ? 0.9 : 0.12
                edge.node.lineWidth = isIncident ? 1.5 : 1
            } else {
                edge.node.strokeColor = .separatorColor
                edge.node.alpha = 0.6
                edge.node.lineWidth = 1
            }
        }
    }

    private func zoom(by factor: Double) {
        let scale = min(
            LocalGraphCamera.maximumScale,
            max(LocalGraphCamera.minimumManualScale, graphCamera.xScale * factor)
        )
        graphCamera.xScale = scale
        graphCamera.yScale = scale
        updateNodeAppearance()
    }

    private func fit(animated: Bool) {
        guard let graph, !graph.nodes.isEmpty else { return }
        let points = graph.nodes.map { CGPoint(x: $0.position.x, y: -$0.position.y) }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let width = max(24, maxX - minX + 36)
        let height = max(24, maxY - minY + 36)
        let targetScale = LocalGraphCamera.fitScale(
            contentSize: CGSize(width: width, height: height),
            viewSize: size
        )
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        if animated {
            let move = SKAction.move(to: center, duration: 0.2)
            let scale = SKAction.scale(to: targetScale, duration: 0.2)
            move.timingMode = .easeInEaseOut
            scale.timingMode = .easeInEaseOut
            let refresh = SKAction.run { [weak self] in
                self?.updateNodeAppearance()
            }
            graphCamera.run(.sequence([.group([move, scale]), refresh]), withKey: "fit")
        } else {
            graphCamera.removeAction(forKey: "fit")
            graphCamera.position = center
            graphCamera.setScale(targetScale)
            updateNodeAppearance()
        }
    }
}

private final class GraphNoteSprite: SKShapeNode {
    let noteID: NoteID
    private let titleLabel: SKLabelNode
    private let baseColor: NSColor
    private let baseRadius: CGFloat

    static func radius(forDegree degree: Int) -> CGFloat {
        min(11, 3.5 + sqrt(CGFloat(max(0, degree))) * 1.35)
    }

    init(noteID: NoteID, title: String, radius: CGFloat, color: NSColor) {
        self.noteID = noteID
        self.baseColor = color
        self.baseRadius = radius
        self.titleLabel = SKLabelNode(fontNamed: NSFont.systemFont(ofSize: 10, weight: .medium).fontName)
        super.init()
        path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
            transform: nil
        )
        fillColor = color
        titleLabel.text = title
        titleLabel.fontSize = 10
        titleLabel.fontColor = .labelColor
        titleLabel.horizontalAlignmentMode = .center
        titleLabel.verticalAlignmentMode = .bottom
        titleLabel.position = CGPoint(x: 0, y: radius + 4)
        titleLabel.zPosition = 2
        titleLabel.alpha = 0
        addChild(titleLabel)
    }

    required init?(coder aDecoder: NSCoder) {
        nil
    }

    func setHighlighted(isRoot: Bool, focused: Bool, hovered: Bool) {
        fillColor = isRoot ? .controlAccentColor : baseColor
        strokeColor = focused ? .keyboardFocusIndicatorColor : .clear
        lineWidth = focused ? 2.5 : 0
        let scale: CGFloat = hovered ? 1.35 : 1
        setScale(scale)
    }

    func setLabelAlpha(_ alpha: CGFloat) {
        titleLabel.alpha = alpha
        titleLabel.isHidden = alpha <= 0.01
        // Counter the node's hover scale so text stays crisp and constant-size.
        titleLabel.setScale(1 / max(0.01, xScale))
    }
}
