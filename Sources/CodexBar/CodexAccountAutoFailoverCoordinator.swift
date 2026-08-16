import CodexBarCore
import Foundation

/// Opt-in background failover for managed Codex accounts.
///
/// Listens for completed multi-account Codex refreshes and, when the **system** account — the credentials the Codex
/// CLI and app read from the ambient `CODEX_HOME/auth.json` — has dropped to the configured headroom threshold,
/// promotes the healthiest managed account into that slot through the same `CodexAccountPromotionCoordinator` path
/// as the manual "System Account" menu.
///
/// Selecting a different row in the menu switcher only changes what CodexBar displays; it never feeds this decision.
@MainActor
final class CodexAccountAutoFailoverCoordinator {
    static let cooldown: TimeInterval = 10 * 60
    static let notificationPrefix = "codex-auto-failover"

    private let settings: SettingsStore
    private let usageStore: UsageStore
    private let promotionCoordinator: CodexAccountPromotionCoordinator
    private let notificationPoster: @MainActor (String, String, String) -> Void
    private let now: () -> Date
    private let logger = CodexBarLog.logger("codex-auto-failover")

    private(set) var isEvaluating = false
    private(set) var lastSwitchAt: Date?
    private(set) var lastDecision: CodexAccountFailoverPolicy.Decision?

    init(
        settings: SettingsStore,
        usageStore: UsageStore,
        promotionCoordinator: CodexAccountPromotionCoordinator,
        notificationPoster: @escaping @MainActor (String, String, String) -> Void = { prefix, title, body in
            AppNotifications.shared.post(idPrefix: prefix, title: title, body: body)
        },
        now: @escaping () -> Date = { Date() })
    {
        self.settings = settings
        self.usageStore = usageStore
        self.promotionCoordinator = promotionCoordinator
        self.notificationPoster = notificationPoster
        self.now = now
    }

    /// Subscribes to `UsageStore` multi-account refresh completions.
    func activate() {
        self.usageStore.onCodexAccountSnapshotsDidRefresh = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                _ = await self.evaluateIfNeeded()
            }
        }
    }

    /// Returns the promotion result when a switch was attempted, `nil` when no switch was needed or allowed.
    @discardableResult
    func evaluateIfNeeded()
        async -> Result<CodexAccountPromotionResult, CodexSystemAccountPromotionUserFacingError>?
    {
        guard self.settings.codexAutoFailoverEnabled else { return nil }
        guard !self.isEvaluating else { return nil }
        guard !self.promotionCoordinator.isInteractionBlocked() else { return nil }
        if let lastSwitchAt, self.now().timeIntervalSince(lastSwitchAt) < Self.cooldown {
            return nil
        }

        let projection = self.settings.codexVisibleAccountProjection
        guard let decision = CodexAccountFailoverPolicy.decide(
            snapshots: self.usageStore.codexAccountSnapshots,
            systemVisibleAccountID: projection.liveVisibleAccountID,
            thresholdPercent: self.settings.codexAutoFailoverThresholdPercent)
        else {
            return nil
        }

        self.isEvaluating = true
        defer { self.isEvaluating = false }
        self.lastDecision = decision
        self.logger.info(
            "auto failover: promoting managed account into the system slot",
            metadata: [
                "from": decision.systemDisplayName,
                "to": decision.targetDisplayName,
                "systemHeadroom": String(format: "%.1f", decision.systemHeadroomPercent),
                "targetHeadroom": String(format: "%.1f", decision.targetHeadroomPercent),
            ])

        let result = await self.promotionCoordinator.promote(
            managedAccountID: decision.targetManagedAccountID,
            trigger: .automaticFailover)
        switch result {
        case .success:
            self.lastSwitchAt = self.now()
            self.notificationPoster(
                Self.notificationPrefix,
                L("Codex system account switched"),
                String(
                    format: L("codex_auto_failover_switched_body"),
                    decision.systemDisplayName,
                    decision.targetDisplayName))
        case let .failure(error):
            // Background failure: log only, the next refresh will retry after cooldown-free re-evaluation.
            self.logger.warning(
                "auto failover: promotion failed",
                metadata: ["title": error.title, "message": error.message])
        }
        return result
    }
}
