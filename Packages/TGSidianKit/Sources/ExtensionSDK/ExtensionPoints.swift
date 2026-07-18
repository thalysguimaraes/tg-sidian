import AppCore
import Foundation
import SwiftUI

@MainActor
public protocol SettingsPaneProviding {
    var settingsPaneTitle: String { get }
    var settingsPaneIcon: String { get }
    func settingsPane() -> AnyView
}

@MainActor
public protocol DailyNoteHeaderProviding {
    func dailyNoteHeader(for date: Date) -> AnyView?
}

public struct ExtensionColor: Codable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }
}

public enum ExtensionIcon: Codable, Hashable, Sendable {
    case system(name: String)
    case fontGlyph(glyph: String, fontName: String, fallbackSystemName: String? = nil)
}

public struct TreeDecoration: Codable, Hashable, Sendable {
    public let icon: ExtensionIcon?
    public let tint: ExtensionColor?

    public init(icon: ExtensionIcon? = nil, tint: ExtensionColor? = nil) {
        self.icon = icon
        self.tint = tint
    }
}

@MainActor
public protocol TreeDecorating: Sendable {
    func decoration(for path: RelativePath) -> TreeDecoration?
}

/// Value-only rendering instructions for an inline token. Ranges use UTF-16 offsets, matching
/// TextKit. Providers must return decorations sorted by `sourceRange`, with no overlap, and omit
/// unresolved tokens or tokens intersecting an excluded range. `carrierRange` must have length
/// one and `glyph` must contain exactly one extended grapheme cluster; consumers defensively
/// discard malformed output.
public struct InlineTokenDecoration: Codable, Hashable, Sendable {
    public let sourceRange: NSRange
    public let concealedRanges: [NSRange]
    public let carrierRange: NSRange
    public let glyph: String
    public let fontName: String

    public init(
        sourceRange: NSRange,
        concealedRanges: [NSRange],
        carrierRange: NSRange,
        glyph: String,
        fontName: String
    ) {
        self.sourceRange = sourceRange
        self.concealedRanges = concealedRanges
        self.carrierRange = carrierRange
        self.glyph = glyph
        self.fontName = fontName
    }
}

@MainActor
public protocol InlineTokenConcealing: Sendable {
    func decorations(in text: String, excluding excludedRanges: [NSRange]) -> [InlineTokenDecoration]
}
