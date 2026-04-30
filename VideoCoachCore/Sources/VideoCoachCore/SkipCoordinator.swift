import Foundation

/// Parameters for a single seek issued to the underlying player.
public struct SeekParams: Equatable, Sendable {
    public let targetSeconds: Double
    /// `false` = keyframe-tolerant (cheap on long-GOP HEVC).
    /// `true`  = exact-frame settle (more expensive, used after a burst).
    public let exact: Bool
    public init(targetSeconds: Double, exact: Bool) {
        self.targetSeconds = targetSeconds
        self.exact = exact
    }
}

/// The decision returned from a `SkipCoordinator` event.
///
/// `seek` is non-nil when the caller should issue a player seek.
/// `armDebounceSeconds` is non-nil when the caller should (re)start
/// a burst-end debounce timer of the given duration.
public struct SkipDecision: Equatable, Sendable {
    public let seek: SeekParams?
    public let armDebounceSeconds: Double?
    public init(seek: SeekParams? = nil, armDebounceSeconds: Double? = nil) {
        self.seek = seek
        self.armDebounceSeconds = armDebounceSeconds
    }
    public static let none = SkipDecision()
}

/// Coalesces rapid FF/RW skip presses into a small number of player seeks.
///
/// During a burst we issue at most one keyframe-tolerant ("coarse") seek
/// in flight at a time and accumulate the user's intended target. Once
/// the user stops pressing for `burstWindowSeconds`, an exact-frame seek
/// is issued to settle on the precise frame. This is a pure-logic state
/// machine; the caller wires it to the actual player and timers.
@MainActor
public final class SkipCoordinator {
    private let burstWindow: Double
    private var target: Double?
    private var flying: Double?
    private var flyingExact: Bool = false
    private var exactPending: Bool = false

    public init(burstWindowSeconds: Double = 0.15) {
        self.burstWindow = burstWindowSeconds
    }

    /// Request a skip of `deltaSeconds` from the current accumulated target
    /// (or, if no burst is in progress, from `currentPlayerTimeSeconds`).
    public func requestSkip(
        deltaSeconds: Double,
        currentPlayerTimeSeconds: Double,
        clipDurationSeconds: Double,
        nowMonotonicSeconds: TimeInterval
    ) -> SkipDecision {
        let base = target ?? currentPlayerTimeSeconds
        let t = min(max(base + deltaSeconds, 0), clipDurationSeconds)
        target = t
        exactPending = false
        if flying == nil {
            flying = t
            flyingExact = false
            return SkipDecision(seek: .init(targetSeconds: t, exact: false),
                                armDebounceSeconds: burstWindow)
        }
        return SkipDecision(armDebounceSeconds: burstWindow)
    }

    /// Notify the coordinator that the in-flight seek has completed.
    ///
    /// Intended transitions (see plan section 1.3):
    /// (a) clear `exactPending` unconditionally;
    /// (b) if `exactPending && target != nil` → fire an exact seek to `target`;
    /// (c) if the completed seek was coarse and `target` advanced during flight → refire coarse to the latest `target`;
    /// (d) else if the completed seek landed exact, clear `target`; otherwise no-op.
    // TODO(plan-1.3): implement the seek-completion settle logic described above.
    public func seekCompleted(nowMonotonicSeconds: TimeInterval) -> SkipDecision { .none }

    /// Notify the coordinator that the burst-end debounce has fired.
    ///
    /// Intended transitions (see plan section 1.4):
    /// if no seek is currently flying, fire an exact seek to `target`;
    /// otherwise set `exactPending = true` and let `seekCompleted` issue the
    /// exact-frame settle when the in-flight seek lands.
    // TODO(plan-1.4): implement the burst-end debounce settle logic described above.
    public func burstEnded(nowMonotonicSeconds: TimeInterval) -> SkipDecision { .none }

    /// Used when the active player swaps. Clears transient skip state
    /// (`target`, `flying`, `flyingExact`, `exactPending`) only; the
    /// configured `burstWindow` is preserved across resets.
    public func reset() {
        target = nil; flying = nil; flyingExact = false; exactPending = false
    }
}
