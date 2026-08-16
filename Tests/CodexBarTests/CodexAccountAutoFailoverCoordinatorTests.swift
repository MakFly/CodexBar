import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexAccountAutoFailoverCoordinatorTests {
    @MainActor
    private struct Fixture {
        let container: CodexAccountPromotionTestContainer
        let systemVisibleAccountID: String

        func visibleAccount(email: String) throws -> CodexVisibleAccount {
            try #require(self.container.settings.codexVisibleAccountProjection.visibleAccounts
                .first { $0.email == email })
        }

        func seedSnapshots(_ headroomByEmail: [String: Double]) {
            self.container.usageStore.codexAccountSnapshots = self.container.settings
                .codexVisibleAccountProjection.visibleAccounts
                .compactMap { account in
                    guard let headroom = headroomByEmail[account.email] else { return nil }
                    return CodexAccountAutoFailoverCoordinatorTests.snapshot(account, headroom: headroom)
                }
        }

        func makeCoordinator(
            notificationPoster: @escaping @MainActor (String, String, String) -> Void = { _, _, _ in },
            now: @escaping () -> Date = { Date() }) -> CodexAccountAutoFailoverCoordinator
        {
            CodexAccountAutoFailoverCoordinator(
                settings: self.container.settings,
                usageStore: self.container.usageStore,
                promotionCoordinator: CodexAccountPromotionCoordinator(service: self.container.makeService()),
                notificationPoster: notificationPoster,
                now: now)
        }
    }

    /// Builds a live/system account plus one managed account per extra email.
    private static func makeFixture(suiteName: String, managedEmails: [String]) throws -> Fixture {
        let container = try CodexAccountPromotionTestContainer(suiteName: suiteName)
        let managed = try managedEmails.enumerated().map { index, email in
            try container.createManagedAccount(persistedEmail: email, authAccountID: "acct-\(index)")
        }
        try container.persistAccounts(managed)
        _ = try container.writeLiveOAuthAuthFile(email: "system@example.com", accountID: "acct-system")

        let projection = container.settings.codexVisibleAccountProjection
        let systemID = try #require(projection.liveVisibleAccountID)
        #expect(projection.activeVisibleAccountID == systemID)
        return Fixture(container: container, systemVisibleAccountID: systemID)
    }

    private static func snapshot(_ account: CodexVisibleAccount, headroom: Double) -> CodexAccountUsageSnapshot {
        CodexAccountUsageSnapshot(
            account: account,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100 - headroom,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            error: nil,
            sourceLabel: "test")
    }

    @Test
    func `stays idle while the setting is off`() async throws {
        let fixture = try Self.makeFixture(
            suiteName: "CodexAccountAutoFailoverCoordinatorTests-off",
            managedEmails: ["spare@example.com"])
        defer { fixture.container.tearDown() }
        fixture.seedSnapshots(["system@example.com": 0, "spare@example.com": 90])
        var posted: [String] = []
        let coordinator = fixture.makeCoordinator(notificationPoster: { prefix, _, _ in posted.append(prefix) })

        let result = await coordinator.evaluateIfNeeded()

        #expect(result == nil)
        #expect(posted.isEmpty)
        #expect(fixture.container.settings.codexVisibleAccountProjection.liveVisibleAccountID
            == fixture.systemVisibleAccountID)
    }

    @Test
    func `promotes the healthiest managed account once and then respects the cooldown`() async throws {
        let fixture = try Self.makeFixture(
            suiteName: "CodexAccountAutoFailoverCoordinatorTests-promote",
            managedEmails: ["spare@example.com"])
        defer { fixture.container.tearDown() }
        fixture.container.settings.codexAutoFailoverEnabled = true
        fixture.seedSnapshots(["system@example.com": 0, "spare@example.com": 90])
        let spare = try fixture.visibleAccount(email: "spare@example.com")
        var posted: [(String, String, String)] = []
        var now = Date(timeIntervalSince1970: 1_000_000)
        let coordinator = fixture.makeCoordinator(
            notificationPoster: { prefix, title, body in posted.append((prefix, title, body)) },
            now: { now })

        let first = await coordinator.evaluateIfNeeded()

        guard case let .success(promotion)? = first else {
            Issue.record("Expected a successful promotion, got \(String(describing: first))")
            return
        }
        #expect(promotion.targetManagedAccountID == spare.storedAccountID)
        #expect(promotion.outcome == .promoted)
        #expect(fixture.container.settings.codexActiveSource == .liveSystem)
        #expect(fixture.container.settings.codexVisibleAccountProjection.liveVisibleAccountID == spare.id)
        #expect(posted.count == 1)
        #expect(posted.first?.0 == CodexAccountAutoFailoverCoordinator.notificationPrefix)
        // The notification names both ends of the swap so it is unambiguous which account the CLI now uses.
        #expect(posted.first?.2.contains("system@example.com") == true)
        #expect(posted.first?.2.contains("spare@example.com") == true)
        #expect(coordinator.lastDecision?.targetVisibleAccountID == spare.id)

        // Re-arm an exhausted system account: still inside the cooldown → no second switch.
        fixture.seedSnapshots(["system@example.com": 90, "spare@example.com": 0])
        now = now.addingTimeInterval(CodexAccountAutoFailoverCoordinator.cooldown - 1)
        let second = await coordinator.evaluateIfNeeded()
        #expect(second == nil)
        #expect(posted.count == 1)
    }

    @Test
    func `does nothing while the system account still has headroom`() async throws {
        let fixture = try Self.makeFixture(
            suiteName: "CodexAccountAutoFailoverCoordinatorTests-healthy",
            managedEmails: ["spare@example.com"])
        defer { fixture.container.tearDown() }
        fixture.container.settings.codexAutoFailoverEnabled = true
        fixture.seedSnapshots(["system@example.com": 55, "spare@example.com": 90])
        let coordinator = fixture.makeCoordinator()

        let result = await coordinator.evaluateIfNeeded()

        #expect(result == nil)
        #expect(fixture.container.settings.codexVisibleAccountProjection.liveVisibleAccountID
            == fixture.systemVisibleAccountID)
    }

    @Test
    func `displaying a drained account in the switcher never swaps credentials`() async throws {
        let fixture = try Self.makeFixture(
            suiteName: "CodexAccountAutoFailoverCoordinatorTests-displayed",
            managedEmails: ["drained@example.com", "spare@example.com"])
        defer { fixture.container.tearDown() }
        fixture.container.settings.codexAutoFailoverEnabled = true

        // The user selects a drained account for display only; the System account is healthy.
        let drained = try fixture.visibleAccount(email: "drained@example.com")
        #expect(fixture.container.settings.selectCodexVisibleAccount(id: drained.id))
        #expect(fixture.container.settings.codexVisibleAccountProjection.activeVisibleAccountID == drained.id)
        #expect(fixture.container.settings.codexVisibleAccountProjection.liveVisibleAccountID
            == fixture.systemVisibleAccountID)
        fixture.seedSnapshots([
            "system@example.com": 60,
            "drained@example.com": 0,
            "spare@example.com": 95,
        ])
        let coordinator = fixture.makeCoordinator()

        let result = await coordinator.evaluateIfNeeded()

        #expect(result == nil)
        #expect(coordinator.lastDecision == nil)
        #expect(fixture.container.settings.codexVisibleAccountProjection.liveVisibleAccountID
            == fixture.systemVisibleAccountID)
    }

    @Test
    func `fails over on the system account even while another account is displayed`() async throws {
        let fixture = try Self.makeFixture(
            suiteName: "CodexAccountAutoFailoverCoordinatorTests-displayed-other",
            managedEmails: ["drained@example.com", "spare@example.com"])
        defer { fixture.container.tearDown() }
        fixture.container.settings.codexAutoFailoverEnabled = true

        let drained = try fixture.visibleAccount(email: "drained@example.com")
        let spare = try fixture.visibleAccount(email: "spare@example.com")
        #expect(fixture.container.settings.selectCodexVisibleAccount(id: drained.id))
        fixture.seedSnapshots([
            "system@example.com": 2,
            "drained@example.com": 0,
            "spare@example.com": 95,
        ])
        let coordinator = fixture.makeCoordinator()

        let result = await coordinator.evaluateIfNeeded()

        guard case let .success(promotion)? = result else {
            Issue.record("Expected a successful promotion, got \(String(describing: result))")
            return
        }
        #expect(promotion.targetManagedAccountID == spare.storedAccountID)
        #expect(fixture.container.settings.codexVisibleAccountProjection.liveVisibleAccountID == spare.id)
    }

    @Test
    func `skips while another account operation is in flight`() async throws {
        let fixture = try Self.makeFixture(
            suiteName: "CodexAccountAutoFailoverCoordinatorTests-blocked",
            managedEmails: ["spare@example.com"])
        defer { fixture.container.tearDown() }
        fixture.container.settings.codexAutoFailoverEnabled = true
        fixture.seedSnapshots(["system@example.com": 0, "spare@example.com": 90])
        let promotionCoordinator = CodexAccountPromotionCoordinator(service: fixture.container.makeService())
        promotionCoordinator.setLiveReauthenticationInProgress(true)
        let coordinator = CodexAccountAutoFailoverCoordinator(
            settings: fixture.container.settings,
            usageStore: fixture.container.usageStore,
            promotionCoordinator: promotionCoordinator,
            notificationPoster: { _, _, _ in })

        let result = await coordinator.evaluateIfNeeded()

        #expect(result == nil)
        #expect(fixture.container.settings.codexVisibleAccountProjection.liveVisibleAccountID
            == fixture.systemVisibleAccountID)
    }

    @Test
    func `threshold setting is sanitized and defaults to ten percent`() throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountAutoFailoverCoordinatorTests-threshold")
        defer { container.tearDown() }
        #expect(container.settings.codexAutoFailoverEnabled == false)
        #expect(container.settings.codexAutoFailoverThresholdPercent == 10)
        container.settings.codexAutoFailoverThresholdPercent = 200
        #expect(container.settings.codexAutoFailoverThresholdPercent == 50)
        container.settings.codexAutoFailoverThresholdPercent = -5
        #expect(container.settings.codexAutoFailoverThresholdPercent == 0)
        container.settings.codexAutoFailoverThresholdPercent = 20
        #expect(container.settings.codexAutoFailoverThresholdPercent == 20)
    }
}
