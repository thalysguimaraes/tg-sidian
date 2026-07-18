import AppCore
import Foundation

public actor DailyNoteService {
    private let vault: VaultActor
    private var configuration: DailyNoteConfiguration

    public init(vault: VaultActor, configuration: DailyNoteConfiguration = .default) {
        self.vault = vault
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: DailyNoteConfiguration) {
        self.configuration = configuration
    }

    @discardableResult
    public func openOrCreate(date: Date) async throws -> VaultFileSnapshot {
        let path = try configuration.path(for: date)
        if try await vault.exists(path) {
            return try await vault.read(path)
        }

        let dateText = configuration.templateDateText(for: date)

        let template: String
        if let templatePath = configuration.templatePath,
           let snapshot = try? await vault.read(templatePath) {
            template = snapshot.content
        } else {
            template = "# {{date}}\n"
        }
        let content = template
            .replacingOccurrences(of: "{{date}}", with: dateText)
            .replacingOccurrences(of: "{{title}}", with: dateText)

        do {
            return try await vault.atomicWrite(content, to: path, expectedFingerprint: nil)
        } catch TGSidianError.destinationExists {
            return try await vault.read(path)
        }
    }

}
