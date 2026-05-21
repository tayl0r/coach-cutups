import Foundation

// Reuses RGBA from Stroke.swift (public struct RGBA: Codable, Hashable, Sendable).

public struct TeamConfig: Codable, Hashable, Sendable {
    public var name: String
    public var primaryColor: RGBA
    public var secondaryColor: RGBA
    public var fontColor: RGBA

    public init(name: String, primaryColor: RGBA, secondaryColor: RGBA, fontColor: RGBA? = nil) {
        self.name = name
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.fontColor = fontColor ?? secondaryColor
    }
}

public struct ScoreboardConfig: Codable, Hashable, Sendable {
    public var home: TeamConfig
    public var away: TeamConfig
    public var format: MatchFormat

    public init(home: TeamConfig, away: TeamConfig, format: MatchFormat = .init()) {
        self.home = home
        self.away = away
        self.format = format
    }
}
