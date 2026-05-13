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
/// The first press of any sequence issues an exact-frame seek directly —
/// no coarse-then-refine for single keypresses, since on long-GOP HEVC the
/// "coarse" landing visibly snaps to the keyframe before the target (e.g.
/// +2s for a +3s skip) and the burst-end debounce then jumps the rest of
/// the way, producing a perceived double-seek for one keypress.
///
/// Follow-up presses inside the same burst accumulate the user's intended
/// target. When the leading exact lands while a follow-up target has piled
/// up, the coordinator switches into burst mode: a keyframe-tolerant
/// ("coarse") seek to the latest target with a refreshed debounce. Once
/// the user stops pressing for `burstWindowSeconds`, an exact-frame seek
/// settles on the precise frame.
///
/// This is a pure-logic state machine; the caller wires it to the actual
/// player and timers.
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
            // Leading press: issue exact directly so a single keypress
            // produces one frame-precise jump. `target` stays set so a
            // follow-up press during this seek's flight uses it as the
            // base; if no follow-up arrives, `seekCompleted` clears it.
            // No debounce — there's nothing left to settle to.
            flying = t
            flyingExact = true
            return SkipDecision(seek: .init(targetSeconds: t, exact: true))
        }
        // Follow-up press during flight: accumulate target only and
        // (re)arm the burst-end debounce. The actual coarse seek is
        // issued by `seekCompleted` once the leading exact lands.
        return SkipDecision(armDebounceSeconds: burstWindow)
    }

    /// Notify the coordinator that the in-flight seek has completed.
    ///
    /// Branches, in order:
    /// (a) If `exactPending` was set (the burst-end debounce fired during
    ///     this seek's flight), issue an exact settle to `target` if any.
    /// (b) Leading exact landed and a follow-up press piled up a new target
    ///     during flight: switch into burst mode — fire a coarse seek to
    ///     the new target and arm the burst-end debounce. (For a true
    ///     single press, `target == landedTarget` here, so this collapses
    ///     to the next branch and no follow-up seek is issued.)
    /// (c) Leading exact landed with no pending target: clear and no-op.
    /// (d) Coarse landed and `target` advanced past the landed position
    ///     during flight: refire coarse to the latest `target`. (No debounce
    ///     re-arm needed — the press that advanced `target` armed it.)
    /// (e) Otherwise no-op.
    public func seekCompleted(nowMonotonicSeconds: TimeInterval) -> SkipDecision {
        let landedTarget = flying
        let landedExact = flyingExact
        flying = nil
        if exactPending {
            exactPending = false
            if let t = target {
                flying = t; flyingExact = true
                target = nil
                return SkipDecision(seek: .init(targetSeconds: t, exact: true))
            }
            return .none
        }
        if landedExact {
            if let tgt = target, tgt != landedTarget {
                flying = tgt; flyingExact = false
                return SkipDecision(seek: .init(targetSeconds: tgt, exact: false),
                                    armDebounceSeconds: burstWindow)
            }
            target = nil
            return .none
        }
        if let tgt = target, tgt != landedTarget {
            flying = tgt; flyingExact = false
            return SkipDecision(seek: .init(targetSeconds: tgt, exact: false))
        }
        return .none
    }

    /// Notify the coordinator that the burst-end debounce has fired.
    ///
    /// If no seek is currently flying, fires an exact seek to `target` and
    /// consumes `target` (transferring it to `flying`). If a seek is in
    /// flight, sets `exactPending = true` so `seekCompleted` will issue the
    /// exact-frame settle once the in-flight seek lands.
    public func burstEnded(nowMonotonicSeconds: TimeInterval) -> SkipDecision {
        if flying == nil, let t = target {
            flying = t
            flyingExact = true
            target = nil
            return SkipDecision(seek: .init(targetSeconds: t, exact: true))
        }
        // Only set exactPending when there is a target to settle to — preserves
        // the invariant that target is non-nil whenever exactPending is set.
        if flying != nil, target != nil {
            exactPending = true
        }
        return .none
    }

    /// Used when the active player swaps. Clears transient skip state
    /// (`target`, `flying`, `flyingExact`, `exactPending`) only; the
    /// configured `burstWindow` is preserved across resets.
    public func reset() {
        target = nil; flying = nil; flyingExact = false; exactPending = false
    }
}
