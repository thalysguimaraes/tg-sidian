import AppCore
import Foundation
import TestSupport
import Testing
import VaultKit

@Suite("Daily notes", .serialized)
struct DailyNotesTests {
    @Test("daily note creation is templated and idempotent")
    func dailyNote() async throws {
        let fixture = try makeFixture()
        let configuration = DailyNoteConfiguration(
            folder: try RelativePath("Daily Notes"),
            filenamePattern: "yyyy-MM-dd'.md'",
            templatePath: try RelativePath("Templates/Daily.md"),
            localeIdentifier: "en_US_POSIX",
            timeZoneIdentifier: "UTC"
        )
        let service = DailyNoteService(vault: fixture.vault, configuration: configuration)
        let date = Date(timeIntervalSince1970: 1_752_537_600) // 2025-07-15 UTC

        let first = try await service.openOrCreate(date: date)
        let second = try await service.openOrCreate(date: date)
        let expectedPath = try RelativePath("Daily Notes/2025-07-15.md")
        #expect(first.path == expectedPath)
        #expect(first.content.contains("# 2025-07-15"))
        #expect(first.fingerprint == second.fingerprint)
        let files = try await fixture.vault.listMarkdownFiles()
        #expect(files.filter { $0.rawValue == "Daily Notes/2025-07-15.md" }.count == 1)
    }

    private func makeFixture() throws -> TemporaryVault {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/AcceptanceVault", isDirectory: true)
        return try TemporaryVault(copying: url)
    }
}

@Suite("Canonical today")
struct CanonicalTodayTests {
    /// West of Greenwich, evenings cross the UTC day boundary before the local one. "Today"
    /// must follow the wall clock: 23:00 in São Paulo on July 16 is already July 17 in UTC,
    /// but the canonical daily note for that moment is still 2026-07-16.
    @Test("canonical today follows the local wall clock, not the configured UTC calendar")
    func canonicalTodayFollowsLocalClock() throws {
        let configuration = DailyNoteConfiguration.default

        var saoPaulo = Calendar(identifier: .gregorian)
        saoPaulo.timeZone = TimeZone(identifier: "America/Sao_Paulo")!

        // 2026-07-16 23:00 in São Paulo == 2026-07-17 02:00 UTC.
        var evening = DateComponents()
        evening.year = 2026
        evening.month = 7
        evening.day = 16
        evening.hour = 23
        let lateLocalEvening = saoPaulo.date(from: evening)!

        let canonical = configuration.canonicalToday(now: lateLocalEvening, local: saoPaulo)
        #expect(configuration.filename(for: canonical) == "2026-07-16.md")
        #expect(configuration.isCanonicalDateToday(canonical, now: lateLocalEvening, local: saoPaulo))

        // The naive UTC reading of the same instant is the 17th — and must NOT be today.
        let utcDay = configuration.date(fromFilename: "2026-07-17.md")!
        #expect(!configuration.isCanonicalDateToday(utcDay, now: lateLocalEvening, local: saoPaulo))
    }
}
