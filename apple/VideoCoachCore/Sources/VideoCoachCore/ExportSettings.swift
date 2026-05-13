import Foundation

public struct PixelSize: Equatable, Sendable {
    public var width: Int, height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum ExportSettings {
    public static func bitrate(resolution: Resolution, quality: Quality) -> Int {
        let base1080: [Quality: Int] = [.low: 6_000_000, .medium: 12_000_000, .high: 24_000_000]
        let v = base1080[quality]!
        switch resolution {
        case .source, .r1080: return v
        case .r720:           return v / 2
        }
    }

    public static func pixelSize(resolution: Resolution) -> PixelSize {
        switch resolution {
        case .source: return .init(width: 1920, height: 1080) // overridden by source asset at export
        case .r1080:  return .init(width: 1920, height: 1080)
        case .r720:   return .init(width: 1280, height: 720)
        }
    }
}
