import AppCore
import Foundation
import VaultKit

public final class TemporaryVault {
    public let rootURL: URL
    public let vault: VaultActor
    private let removeOnDeinit: Bool

    public init(copying fixtureURL: URL, removeOnDeinit: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureURL, to: root)
        self.rootURL = root
        self.vault = try VaultActor(rootURL: root)
        self.removeOnDeinit = removeOnDeinit
    }

    public init(emptyNamed name: String = "vault", removeOnDeinit: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-sidian-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.rootURL = root
        self.vault = try VaultActor(rootURL: root)
        self.removeOnDeinit = removeOnDeinit
    }

    deinit {
        if removeOnDeinit {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    public func directWrite(_ content: String, to relativePath: String) throws {
        let path = try RelativePath(relativePath)
        let url = rootURL.appendingPathComponent(path.rawValue)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
}

public enum FixtureVaultGenerator {
    public static func generate(
        at rootURL: URL,
        noteCount: Int,
        seed: UInt64 = 1
    ) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var state = seed
        for index in 0..<noteCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let folder = "Folder-\(index % 20)"
            let path = rootURL.appendingPathComponent(folder).appendingPathComponent("Note-\(index).md")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let target = index == 0 ? 0 : Int(state % UInt64(index))
            let type = ["idea", "reading", "tool", "watch", "meeting"][index % 5]
            let content = """
            ---
            title: Note \(index)
            type: \(type)
            tags: [fixture, tag-\(index % 13)]
            ---
            # Note \(index)

            Deterministic fixture body \(state).

            [[Note \(target)]]
            """
            try Data(content.utf8).write(to: path)
        }
    }
}
