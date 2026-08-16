import Foundation

/// What caused a Codex system-account switch, so the island can say so.
enum CodexAccountSwitchTrigger: Equatable, Sendable {
    case manual
    case automaticFailover
}

/// Presentation state for the Codex system-account switch island.
///
/// Pure value type so the phase transitions and lifetimes are testable without AppKit. Mirrors
/// ``QuotaWarningAlertPresentationState``: every presentation carries a generation so a stale auto-dismissal
/// can never take down a newer one.
struct CodexAccountSwitchIslandState {
    static let switchingLifetime: TimeInterval = 30
    static let succeededLifetime: TimeInterval = 4.5
    static let failedLifetime: TimeInterval = 6

    enum Phase: Equatable {
        case switching(target: String, trigger: CodexAccountSwitchTrigger)
        case succeeded(target: String, trigger: CodexAccountSwitchTrigger)
        case failed(message: String, trigger: CodexAccountSwitchTrigger)

        /// The switching phase is bounded only as a safety net: a promotion that never reports back must not
        /// leave a spinner pinned under the notch forever.
        var lifetime: TimeInterval {
            switch self {
            case .switching:
                CodexAccountSwitchIslandState.switchingLifetime
            case .succeeded:
                CodexAccountSwitchIslandState.succeededLifetime
            case .failed:
                CodexAccountSwitchIslandState.failedLifetime
            }
        }

        var isTerminal: Bool {
            switch self {
            case .switching:
                false
            case .succeeded, .failed:
                true
            }
        }
    }

    struct Presentation: Equatable {
        let generation: UInt
        let phase: Phase

        var lifetime: TimeInterval {
            self.phase.lifetime
        }
    }

    private(set) var current: Presentation?
    private var nextGeneration: UInt = 0

    mutating func present(_ phase: Phase) -> Presentation {
        self.nextGeneration &+= 1
        let presentation = Presentation(generation: self.nextGeneration, phase: phase)
        self.current = presentation
        return presentation
    }

    /// Moves an in-flight switch to its outcome. Returns `nil` when nothing is being shown, so a result that
    /// arrives after the island was dismissed does not resurrect it.
    mutating func resolve(_ phase: Phase) -> Presentation? {
        guard self.current != nil else { return nil }
        return self.present(phase)
    }

    mutating func dismiss(generation: UInt) -> Bool {
        guard self.current?.generation == generation else { return false }
        self.current = nil
        return true
    }

    mutating func dismiss() {
        self.current = nil
    }
}
