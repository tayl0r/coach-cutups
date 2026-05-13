import Foundation

public struct CommentaryEvent: Codable, Hashable, Sendable {
    public var recordTime: Double
    public var kind: Kind
    public init(recordTime: Double, kind: Kind) {
        self.recordTime = recordTime
        self.kind = kind
    }

    public enum Kind: Hashable, Sendable {
        /// `sourceTime` is mpv's actual `timePos` captured at the keystroke
        /// moment — anchors the segment-builder's `sourceCursor` to where
        /// the source video ACTUALLY was, instead of relying on the cursor
        /// advancing at exactly 1× wall-clock during the preceding play
        /// period. mpv play/pause latency and frame-boundary rounding make
        /// the computed cursor drift by tens of ms; the captured value
        /// pins the freeze frame to what was visibly on screen when the
        /// user pressed space.
        case play(sourceTime: Double)
        case pause(sourceTime: Double)
        case skip(delta: Double)
        case stroke(Stroke)
        case clearAll
        case zoom(Zoom)
        case unknown           // Forward-compat: future kinds we don't recognize
    }
}

// Manual Codable for Kind so unknown discriminators decode as .unknown
// instead of throwing DecodingError.dataCorrupted. Old builds opening
// new project files don't crash on .zoom or any future variant.
extension CommentaryEvent.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case play, pause, skip, stroke, clearAll, zoom
    }
    private struct SkipPayload: Codable { let delta: Double }
    private struct PlayPausePayload: Codable { let sourceTime: Double }

    public init(from decoder: Decoder) throws {
        // Match Swift's auto-synth: enums with associated values are emitted
        // as a single-key dictionary {"caseName": <payload>} (or {"caseName": {}}
        // for no-payload cases).
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let p = try? container.decode(PlayPausePayload.self, forKey: .play) {
            self = .play(sourceTime: p.sourceTime); return
        }
        if let p = try? container.decode(PlayPausePayload.self, forKey: .pause) {
            self = .pause(sourceTime: p.sourceTime); return
        }
        if container.contains(.clearAll) { self = .clearAll; return }
        if let s = try? container.decode(SkipPayload.self, forKey: .skip) {
            self = .skip(delta: s.delta); return
        }
        if let stroke = try? container.decode(Stroke.self, forKey: .stroke) {
            self = .stroke(stroke); return
        }
        if let z = try? container.decode(Zoom.self, forKey: .zoom) {
            self = .zoom(z); return
        }
        // Unknown discriminator → graceful skip instead of crash.
        self = .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .play(let s):  try container.encode(PlayPausePayload(sourceTime: s), forKey: .play)
        case .pause(let s): try container.encode(PlayPausePayload(sourceTime: s), forKey: .pause)
        case .clearAll:   try container.encode([String:String](), forKey: .clearAll)
        case .skip(let d): try container.encode(SkipPayload(delta: d), forKey: .skip)
        case .stroke(let s): try container.encode(s, forKey: .stroke)
        case .zoom(let z):   try container.encode(z, forKey: .zoom)
        case .unknown:
            // Don't write .unknown back — it represents a kind we couldn't
            // decode, so we can't faithfully re-encode it. Drop on save.
            // (Old builds opening new files don't save them right back; if
            // they DO, the unknown event silently drops, which is acceptable.)
            break
        }
    }
}
