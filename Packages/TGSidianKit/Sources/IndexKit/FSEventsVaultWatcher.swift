import AppCore
@preconcurrency import CoreServices
import Foundation

public enum VaultFileEventKind: String, Hashable, Sendable, Codable {
    case created
    case modified
    case moved
    case renamed
    case removed
    case rescanRequired
    case eventGap
}

/// A normalized, injectable event consumed by `IndexActor`. FSEvents does not provide rename
/// pairs; old and new paths therefore arrive independently and are resolved against the vault.
public struct VaultFileEvent: Hashable, Sendable, Codable {
    public let kind: VaultFileEventKind
    public let path: RelativePath?
    public let eventID: UInt64

    public init(kind: VaultFileEventKind, path: RelativePath? = nil, eventID: UInt64 = 0) {
        self.kind = kind
        self.path = path
        self.eventID = eventID
    }
}

/// Thin FSEvents adapter. The actor owns reconciliation and all database writes; this object only
/// normalizes recursive file events and reports stream gaps explicitly.
final class FSEventsVaultWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([VaultFileEvent]) -> Void

    static var currentEventID: UInt64 { UInt64(FSEventsGetCurrentEventId()) }

    private let rootURL: URL
    private let queue: DispatchQueue
    private let handler: Handler
    private var stream: FSEventStreamRef?

    init(rootURL: URL, since eventID: UInt64?, handler: @escaping Handler) throws {
        // FSEvents reports canonical filesystem paths. Watching and prefix-matching the resolved
        // root keeps POSIX-symlink vault selections observable instead of silently dropping every
        // callback under the target directory.
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.queue = DispatchQueue(label: "design.thalys.tg-sidian.fsevents", qos: .utility)
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let sinceWhen = eventID.flatMap { $0 > 0 ? FSEventStreamEventId($0) : nil }
            ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            [self.rootURL.path] as CFArray,
            sinceWhen,
            0.15,
            flags
        ) else {
            throw TGSidianError.invalidOperation("Could not create the vault FSEvents stream")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw TGSidianError.invalidOperation("Could not start the vault FSEvents stream")
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = {
        _, callbackInfo, eventCount, eventPaths, eventFlags, eventIDs in
        guard let callbackInfo else { return }
        let watcher = Unmanaged<FSEventsVaultWatcher>.fromOpaque(callbackInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        var normalized: [VaultFileEvent] = []
        normalized.reserveCapacity(eventCount)

        for index in 0..<eventCount {
            let flags = eventFlags[index]
            let eventID = UInt64(eventIDs[index])
            if flags.hasAny(
                UInt32(kFSEventStreamEventFlagMustScanSubDirs),
                UInt32(kFSEventStreamEventFlagUserDropped),
                UInt32(kFSEventStreamEventFlagKernelDropped),
                UInt32(kFSEventStreamEventFlagEventIdsWrapped),
                UInt32(kFSEventStreamEventFlagRootChanged)
            ) {
                normalized.append(VaultFileEvent(kind: .eventGap, eventID: eventID))
                continue
            }

            let path = index < paths.count ? watcher.relativePath(for: paths[index]) : nil
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                normalized.append(VaultFileEvent(kind: .rescanRequired, path: path, eventID: eventID))
            } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                normalized.append(VaultFileEvent(kind: .removed, path: path, eventID: eventID))
            } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                normalized.append(VaultFileEvent(kind: .created, path: path, eventID: eventID))
            } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
                normalized.append(VaultFileEvent(kind: .renamed, path: path, eventID: eventID))
            } else {
                normalized.append(VaultFileEvent(kind: .modified, path: path, eventID: eventID))
            }
        }

        if !normalized.isEmpty {
            watcher.handler(normalized)
        }
    }

    private func relativePath(for rawPath: String) -> RelativePath? {
        let path = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = rootURL.path
        guard path != rootPath, path.hasPrefix(rootPath + "/") else { return nil }
        return try? RelativePath(String(path.dropFirst(rootPath.count + 1)))
    }
}

private extension FSEventStreamEventFlags {
    func hasAny(_ values: FSEventStreamEventFlags...) -> Bool {
        values.contains { self & $0 != 0 }
    }
}
