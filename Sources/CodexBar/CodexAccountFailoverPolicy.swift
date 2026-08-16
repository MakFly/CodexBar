import CodexBarCore
import Foundation

/// Shared "remaining headroom" reading for a Codex account: the tighter of the 5-hour and weekly windows.
enum CodexAccountHeadroom {
    static func remainingPercent(_ snapshot: UsageSnapshot?) -> Double? {
        guard let snapshot else { return nil }
        let session = snapshot.primary?.remainingPercent
        let weekly = snapshot.secondary?.remainingPercent
        return switch (session, weekly) {
        case let (.some(session), .some(weekly)):
            min(session, weekly)
        case let (.some(session), .none):
            session
        case let (.none, .some(weekly)):
            weekly
        case (.none, .none):
            nil
        }
    }
}

/// Pure decision logic for opt-in automatic Codex account failover.
///
/// This is deliberately keyed on the **system** account — the credentials in the ambient
/// `CODEX_HOME/auth.json` that the Codex CLI and app actually consume — and never on the account the user has
/// merely selected for display in the menu switcher. Selecting a row in the switcher only changes what CodexBar
/// shows (`codexActiveSource`); it must not be able to trigger, suppress, or retarget a credential swap.
enum CodexAccountFailoverPolicy {
    struct Decision: Equatable {
        let targetManagedAccountID: UUID
        let targetVisibleAccountID: String
        let targetDisplayName: String
        let systemDisplayName: String
        let systemHeadroomPercent: Double
        let targetHeadroomPercent: Double
    }

    /// - Parameter systemVisibleAccountID: the visible account currently holding the live system slot
    ///   (`CodexVisibleAccountProjection.liveVisibleAccountID`), not the displayed/active one.
    static func decide(
        snapshots: [CodexAccountUsageSnapshot],
        systemVisibleAccountID: String?,
        thresholdPercent: Int) -> Decision?
    {
        guard let systemVisibleAccountID,
              let system = snapshots.first(where: { $0.id == systemVisibleAccountID }),
              let systemHeadroom = CodexAccountHeadroom.remainingPercent(system.snapshot)
        else {
            return nil
        }
        let threshold = Double(thresholdPercent)
        guard systemHeadroom <= threshold else { return nil }

        let candidates = snapshots.compactMap { entry -> (CodexAccountUsageSnapshot, UUID, Double)? in
            guard entry.id != systemVisibleAccountID,
                  let managedID = entry.account.storedAccountID,
                  CodexAccountHealth.status(for: entry.account, error: entry.error) == .ok,
                  let headroom = CodexAccountHeadroom.remainingPercent(entry.snapshot),
                  headroom > threshold
            else {
                return nil
            }
            return (entry, managedID, headroom)
        }
        guard let best = candidates.max(by: { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            // Deterministic tie-break: prefer the alphabetically first display name.
            return lhs.0.account.menuDisplayName.lowercased() > rhs.0.account.menuDisplayName.lowercased()
        }) else {
            return nil
        }
        return Decision(
            targetManagedAccountID: best.1,
            targetVisibleAccountID: best.0.id,
            targetDisplayName: best.0.account.menuDisplayName,
            systemDisplayName: system.account.menuDisplayName,
            systemHeadroomPercent: systemHeadroom,
            targetHeadroomPercent: best.2)
    }
}
