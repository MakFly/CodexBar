import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexAccountSwitchIslandStateTests {
    @Test
    func `a newer presentation makes a stale dismissal a no-op`() {
        var state = CodexAccountSwitchIslandState()
        let first = state.present(.switching(target: "a@example.com", trigger: .manual))
        let second = state.present(.switching(target: "b@example.com", trigger: .manual))

        #expect(state.dismiss(generation: first.generation) == false)
        #expect(state.current == second)
        #expect(state.dismiss(generation: second.generation) == true)
        #expect(state.current == nil)
    }

    @Test
    func `resolving replaces the in-flight phase`() {
        var state = CodexAccountSwitchIslandState()
        let switching = state.present(.switching(target: "b@example.com", trigger: .automaticFailover))
        let resolved = state.resolve(.succeeded(target: "b@example.com", trigger: .automaticFailover))

        #expect(resolved?.phase == .succeeded(target: "b@example.com", trigger: .automaticFailover))
        #expect(resolved?.generation != switching.generation)
        #expect(state.current == resolved)
    }

    @Test
    func `an outcome after dismissal never resurrects the island`() {
        var state = CodexAccountSwitchIslandState()
        _ = state.present(.switching(target: "b@example.com", trigger: .manual))
        state.dismiss()

        #expect(state.resolve(.succeeded(target: "b@example.com", trigger: .manual)) == nil)
        #expect(state.current == nil)
    }

    @Test
    func `the spinner is bounded and outcomes are short-lived`() {
        let switching = CodexAccountSwitchIslandState.Phase.switching(target: "b", trigger: .manual)
        let succeeded = CodexAccountSwitchIslandState.Phase.succeeded(target: "b", trigger: .manual)
        let failed = CodexAccountSwitchIslandState.Phase.failed(message: "nope", trigger: .manual)

        #expect(switching.isTerminal == false)
        #expect(succeeded.isTerminal)
        #expect(failed.isTerminal)
        #expect(switching.lifetime == CodexAccountSwitchIslandState.switchingLifetime)
        #expect(succeeded.lifetime < switching.lifetime)
        #expect(failed.lifetime > succeeded.lifetime)
    }

    @Test
    func `the island stays clear of the notch utility band`() {
        // A notch utility pins a wide canvas above CodexBar's overlay level; drawing inside it means being
        // hidden behind its panel.
        let wide = CodexAccountSwitchIslandPlacement.resolve(screenWidth: 2560)
        #expect(wide.anchor == .topTrailing)
        #expect(wide.maxWidth == CodexAccountSwitchIslandPlacement.preferredMaxWidth)

        // 14-inch MacBook Pro: less side room, so the island narrows instead of moving.
        let laptop = CodexAccountSwitchIslandPlacement.resolve(screenWidth: 1512)
        #expect(laptop.anchor == .topTrailing)
        #expect(laptop.maxWidth < CodexAccountSwitchIslandPlacement.preferredMaxWidth)
        #expect(laptop.maxWidth >= CodexAccountSwitchIslandPlacement.minTrailingWidth)

        // Too narrow to say anything useful beside the band, so it drops below it.
        let narrow = CodexAccountSwitchIslandPlacement.resolve(screenWidth: 1024)
        #expect(narrow.anchor == .bottomCenter)

        // Never overlaps the reserved centre band.
        for width in [1024.0, 1280, 1440, 1512, 1920, 2560] as [CGFloat] {
            let placement = CodexAccountSwitchIslandPlacement.resolve(screenWidth: width)
            guard placement.anchor == .topTrailing else { continue }
            let bandEdge = width / 2 + CodexAccountSwitchIslandPlacement.reservedCenterWidth / 2
            let islandLeadingEdge = width - CodexAccountSwitchIslandPlacement.screenMargin - placement.maxWidth
            #expect(islandLeadingEdge >= bandEdge, "island overlaps the reserved band at \(width)pt")
        }
    }

    @Test
    func `each phase carries its own colour`() {
        let switching = CodexAccountSwitchIslandView.tint(for: .switching(target: "b", trigger: .manual))
        let succeeded = CodexAccountSwitchIslandView.tint(for: .succeeded(target: "b", trigger: .manual))
        let failed = CodexAccountSwitchIslandView.tint(for: .failed(message: "nope", trigger: .manual))

        #expect(switching != succeeded)
        #expect(succeeded != failed)
        #expect(switching != failed)
    }

    @Test
    func `titles name the account and distinguish automatic switches`() {
        let manual = CodexAccountSwitchIslandView.title(
            for: .switching(target: "spare@example.com", trigger: .manual))
        let automatic = CodexAccountSwitchIslandView.title(
            for: .switching(target: "spare@example.com", trigger: .automaticFailover))
        let succeeded = CodexAccountSwitchIslandView.title(
            for: .succeeded(target: "spare@example.com", trigger: .automaticFailover))
        let failed = CodexAccountSwitchIslandView.title(
            for: .failed(message: "Could not read the account.", trigger: .manual))

        #expect(manual.contains("spare@example.com"))
        #expect(automatic.contains("spare@example.com"))
        #expect(manual != automatic)
        #expect(succeeded.contains("spare@example.com"))
        #expect(failed == "Could not read the account.")
    }
}

@Suite(.serialized)
@MainActor
struct CodexAccountSwitchEventTests {
    @Test
    func `a manual promotion reports began then succeeded with the account name`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountSwitchEventTests-manual")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(
            persistedEmail: "spare@example.com",
            authAccountID: "acct-spare")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "system@example.com", accountID: "acct-system")

        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService())
        coordinator.displayNameResolver = { [weak settings = container.settings] id in
            settings?.codexVisibleAccountProjection.visibleAccounts.first { $0.storedAccountID == id }?.displayName
        }
        var events: [CodexAccountSwitchEvent] = []
        coordinator.onSwitchEvent = { events.append($0) }

        _ = await coordinator.promote(managedAccountID: target.id)

        #expect(events.map(\.kind) == [.began, .succeeded])
        #expect(events.allSatisfy { $0.trigger == .manual })
        #expect(events.allSatisfy { $0.targetDisplayName == "spare@example.com" })
    }

    @Test
    func `a failed promotion reports the user-facing message`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountSwitchEventTests-failure")
        defer { container.tearDown() }
        _ = try container.writeLiveOAuthAuthFile(email: "system@example.com", accountID: "acct-system")

        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService())
        var events: [CodexAccountSwitchEvent] = []
        coordinator.onSwitchEvent = { events.append($0) }

        // No managed account with this ID exists, so preparation throws.
        let result = await coordinator.promote(managedAccountID: UUID(), trigger: .automaticFailover)

        guard case let .failure(error) = result else {
            Issue.record("Expected the promotion to fail")
            return
        }
        #expect(events.count == 2)
        #expect(events.first?.kind == .began)
        #expect(events.last?.kind == .failed(message: error.message))
        #expect(events.allSatisfy { $0.trigger == .automaticFailover })
    }

    @Test
    func `a blocked promotion never opens the island`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountSwitchEventTests-blocked")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(
            persistedEmail: "spare@example.com",
            authAccountID: "acct-spare")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "system@example.com", accountID: "acct-system")

        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService())
        coordinator.setLiveReauthenticationInProgress(true)
        var events: [CodexAccountSwitchEvent] = []
        coordinator.onSwitchEvent = { events.append($0) }

        _ = await coordinator.promote(managedAccountID: target.id)

        #expect(events.isEmpty)
    }
}
