import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountFailoverPolicyTests {
    private static func account(
        id: String,
        email: String,
        managed: Bool = true,
        isSystem: Bool = false,
        isDisplayed: Bool = false,
        authFingerprint: String? = "fp") -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            authFingerprint: managed ? authFingerprint : nil,
            storedAccountID: managed ? UUID() : nil,
            selectionSource: managed ? .managedAccount(id: UUID()) : .liveSystem,
            isActive: isDisplayed,
            isLive: isSystem,
            canReauthenticate: true,
            canRemove: managed)
    }

    private static func usage(session: Double?, weekly: Double?) -> UsageSnapshot {
        UsageSnapshot(
            primary: session
                .map { RateWindow(usedPercent: $0, windowMinutes: 300, resetsAt: nil, resetDescription: nil) },
            secondary: weekly.map { RateWindow(
                usedPercent: $0,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil) },
            updatedAt: Date())
    }

    private static func snapshot(
        _ account: CodexVisibleAccount,
        session: Double? = nil,
        weekly: Double? = nil,
        error: String? = nil) -> CodexAccountUsageSnapshot
    {
        CodexAccountUsageSnapshot(
            account: account,
            snapshot: error == nil ? self.usage(session: session, weekly: weekly) : nil,
            error: error,
            sourceLabel: "test")
    }

    @Test
    func `headroom is the tighter of the session and weekly windows`() {
        #expect(CodexAccountHeadroom.remainingPercent(Self.usage(session: 40, weekly: 90)) == 10)
        #expect(CodexAccountHeadroom.remainingPercent(Self.usage(session: 40, weekly: nil)) == 60)
        #expect(CodexAccountHeadroom.remainingPercent(Self.usage(session: nil, weekly: 25)) == 75)
        #expect(CodexAccountHeadroom.remainingPercent(Self.usage(session: nil, weekly: nil)) == nil)
        #expect(CodexAccountHeadroom.remainingPercent(nil) == nil)
    }

    @Test
    func `exhausted system account with a healthy managed candidate yields a decision`() {
        let system = Self.account(id: "system", email: "system@example.com", managed: false, isSystem: true)
        let spare = Self.account(id: "spare", email: "spare@example.com")
        let decision = CodexAccountFailoverPolicy.decide(
            snapshots: [
                Self.snapshot(system, session: 100, weekly: 40),
                Self.snapshot(spare, session: 5, weekly: 20),
            ],
            systemVisibleAccountID: "system",
            thresholdPercent: 10)

        #expect(decision?.targetVisibleAccountID == "spare")
        #expect(decision?.targetManagedAccountID == spare.storedAccountID)
        #expect(decision?.systemDisplayName == "system@example.com")
        #expect(decision?.systemHeadroomPercent == 0)
        #expect(decision?.targetHeadroomPercent == 80)
    }

    @Test
    func `the displayed account never drives the decision`() {
        // The menu switcher only changes what CodexBar shows. A drained account the user is merely looking at
        // must not swap the CLI's credentials, and a drained System account must still fail over while the user
        // looks at something else.
        let system = Self.account(id: "system", email: "system@example.com", managed: false, isSystem: true)
        let displayed = Self.account(id: "displayed", email: "displayed@example.com", isDisplayed: true)
        let spare = Self.account(id: "spare", email: "spare@example.com")

        let healthySystem = [
            Self.snapshot(system, session: 20),
            Self.snapshot(displayed, session: 100),
            Self.snapshot(spare, session: 5),
        ]
        #expect(CodexAccountFailoverPolicy.decide(
            snapshots: healthySystem,
            systemVisibleAccountID: "system",
            thresholdPercent: 10) == nil)

        let drainedSystem = [
            Self.snapshot(system, session: 95),
            Self.snapshot(displayed, session: 100),
            Self.snapshot(spare, session: 5),
        ]
        #expect(CodexAccountFailoverPolicy.decide(
            snapshots: drainedSystem,
            systemVisibleAccountID: "system",
            thresholdPercent: 10)?.targetVisibleAccountID == "spare")
    }

    @Test
    func `system account above the threshold never triggers`() {
        let system = Self.account(id: "system", email: "system@example.com", managed: false, isSystem: true)
        let spare = Self.account(id: "spare", email: "spare@example.com")
        let decision = CodexAccountFailoverPolicy.decide(
            snapshots: [Self.snapshot(system, session: 85, weekly: 10), Self.snapshot(spare, session: 0, weekly: 0)],
            systemVisibleAccountID: "system",
            thresholdPercent: 10)
        #expect(decision == nil)
    }

    @Test
    func `threshold is inclusive`() {
        let system = Self.account(id: "system", email: "system@example.com", managed: false, isSystem: true)
        let spare = Self.account(id: "spare", email: "spare@example.com")
        let decision = CodexAccountFailoverPolicy.decide(
            snapshots: [Self.snapshot(system, session: 90, weekly: 10), Self.snapshot(spare, session: 0, weekly: 0)],
            systemVisibleAccountID: "system",
            thresholdPercent: 10)
        #expect(decision?.targetVisibleAccountID == "spare")
    }

    @Test
    func `unknown or missing system headroom never triggers`() {
        let system = Self.account(id: "system", email: "system@example.com", managed: false, isSystem: true)
        let spare = Self.account(id: "spare", email: "spare@example.com")
        #expect(CodexAccountFailoverPolicy.decide(
            snapshots: [Self.snapshot(system, error: "boom"), Self.snapshot(spare, session: 0, weekly: 0)],
            systemVisibleAccountID: "system",
            thresholdPercent: 10) == nil)
        #expect(CodexAccountFailoverPolicy.decide(
            snapshots: [Self.snapshot(spare, session: 0, weekly: 0)],
            systemVisibleAccountID: "system",
            thresholdPercent: 10) == nil)
        #expect(CodexAccountFailoverPolicy.decide(
            snapshots: [Self.snapshot(system, session: 100), Self.snapshot(spare, session: 0)],
            systemVisibleAccountID: nil,
            thresholdPercent: 10) == nil)
    }

    @Test
    func `candidates must be managed, healthy, and above the threshold`() {
        let system = Self.account(id: "system", email: "system@example.com", isSystem: true)
        let notManaged = Self.account(id: "plain", email: "plain@example.com", managed: false)
        let needsReauth = Self.account(id: "reauth", email: "reauth@example.com")
        let missingAuth = Self.account(id: "missing", email: "missing@example.com", authFingerprint: nil)
        let alsoExhausted = Self.account(id: "empty", email: "empty@example.com")
        let decision = CodexAccountFailoverPolicy.decide(
            snapshots: [
                Self.snapshot(system, session: 100),
                Self.snapshot(notManaged, session: 0),
                Self.snapshot(needsReauth, error: "Codex login required. Run `codex login`."),
                Self.snapshot(missingAuth, session: 0),
                Self.snapshot(alsoExhausted, session: 95),
            ],
            systemVisibleAccountID: "system",
            thresholdPercent: 10)
        #expect(decision == nil)
    }

    @Test
    func `the candidate with the most headroom wins with a stable tie-break`() {
        let system = Self.account(id: "system", email: "system@example.com", isSystem: true)
        let mid = Self.account(id: "mid", email: "mid@example.com")
        let best = Self.account(id: "best", email: "best@example.com")
        let tie = Self.account(id: "tie", email: "aaa-tie@example.com")
        let decision = CodexAccountFailoverPolicy.decide(
            snapshots: [
                Self.snapshot(system, session: 100),
                Self.snapshot(mid, session: 50),
                Self.snapshot(best, session: 10, weekly: 30),
                Self.snapshot(tie, session: 30, weekly: 10),
            ],
            systemVisibleAccountID: "system",
            thresholdPercent: 10)
        // best: min(90, 70) = 70; tie: min(70, 90) = 70 → alphabetical email wins.
        #expect(decision?.targetVisibleAccountID == "tie")
        #expect(decision?.targetHeadroomPercent == 70)
    }
}
