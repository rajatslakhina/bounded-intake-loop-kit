import Foundation

/// Arithmetic helpers that never trap.
///
/// Every number that reaches this module has, somewhere upstream, passed through
/// a model response or a tool payload. Those are adversarial inputs in the sense
/// that matters here: they are not attacker-controlled, but they *are* free to be
/// `NaN`, `.infinity`, `-1`, or `1e300`, and Swift's default numeric conversions
/// trap on all four. A trap in an intake pipeline is an app crash on a photo.
///
/// Rather than scattering `guard`s at every call site, all conversion and
/// accumulation goes through this one surface, which is separately unit-tested.
public enum Saturating {

    /// `Int` is 64-bit on every platform this package declares, but the ceiling is
    /// derived from `Int.max` rather than hardcoded so the bound stays correct if
    /// the platform list ever widens to a 32-bit `Int` target.
    ///
    /// `Double` cannot represent `Int.max` exactly (it rounds up to 2^63), so the
    /// comparison below is written as `>=` against the rounded value to keep the
    /// conversion provably in range.
    @usableFromInline static let intMaxAsDouble = Double(Int.max)
    @usableFromInline static let intMinAsDouble = Double(Int.min)

    /// Converts a `Double` to `Int`, clamping instead of trapping.
    ///
    /// Returns `nil` for `NaN` — a caller that gets `nil` has learned something
    /// real (the upstream value was not a number) and should not silently see a
    /// zero, which would reconcile against a total and look like agreement.
    @inlinable
    public static func int(_ value: Double) -> Int? {
        if value.isNaN { return nil }
        if value >= intMaxAsDouble { return Int.max }
        if value <= intMinAsDouble { return Int.min }
        return Int(value)
    }

    /// Addition that clamps at the representable bounds.
    @inlinable
    public static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (partial, overflow) = lhs.addingReportingOverflow(rhs)
        if !overflow { return partial }
        return rhs > 0 ? Int.max : Int.min
    }

    /// Multiplication that clamps at the representable bounds.
    @inlinable
    public static func multiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (partial, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        if !overflow { return partial }
        let negative = (lhs < 0) != (rhs < 0)
        return negative ? Int.min : Int.max
    }

    /// Subtraction that clamps at the representable bounds.
    @inlinable
    public static func subtract(_ lhs: Int, _ rhs: Int) -> Int {
        let (partial, overflow) = lhs.subtractingReportingOverflow(rhs)
        if !overflow { return partial }
        return rhs < 0 ? Int.max : Int.min
    }

    /// Integer division that returns `nil` rather than trapping on a zero divisor
    /// or on the single overflowing case, `Int.min / -1`.
    @inlinable
    public static func divide(_ lhs: Int, _ rhs: Int) -> Int? {
        guard rhs != 0 else { return nil }
        let (partial, overflow) = lhs.dividedReportingOverflow(by: rhs)
        return overflow ? nil : partial
    }

    /// Magnitude as an `Int`, clamped.
    ///
    /// `Swift.abs(Int.min)` traps — `Int.min` has no positive counterpart — and
    /// `Int.min` is reachable here because `declaredTotalMinorUnits` arrives
    /// straight off a model. Clamping to `Int.max` loses exactly one unit of
    /// precision at the single value where precision is already meaningless:
    /// every caller uses this for a comparison against a tolerance, and both
    /// `Int.max` and `|Int.min|` are far past any tolerance.
    @inlinable
    public static func absoluteValue(_ value: Int) -> Int {
        if value == Int.min { return Int.max }
        return value < 0 ? -value : value
    }

    /// `|lhs - rhs|`, saturating at both ends and never trapping.
    @inlinable
    public static func distance(_ lhs: Int, _ rhs: Int) -> Int {
        absoluteValue(subtract(lhs, rhs))
    }

    /// True when a `Double` is safe to use in a monetary comparison: finite and
    /// within a range where `Double`'s 53-bit significand still represents cents
    /// exactly. Beyond roughly 2^53 minor units the comparison in
    /// `LineItemReconciler` would be meaningless rather than merely imprecise.
    @inlinable
    public static func isUsableAmount(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        return abs(value) <= 9_007_199_254.0
    }
}
