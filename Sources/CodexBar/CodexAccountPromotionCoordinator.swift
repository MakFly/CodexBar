import Foundation
import Observation

struct CodexSystemAccountPromotionUserFacingError: Error, Equatable {
    let title: String
    let message: String
}

/// A system-account switch reaching the UI, whatever started it (menu, settings, or automatic failover).
struct CodexAccountSwitchEvent: Equatable {
    enum Kind: Equatable {
        case began
        case succeeded
        case failed(message: String)
    }

    let targetDisplayName: String
    let trigger: CodexAccountSwitchTrigger
    let kind: Kind
}

@MainActor
@Observable
final class CodexAccountPromotionCoordinator {
    let service: CodexAccountPromotionService
    weak var managedAccountCoordinator: ManagedCodexAccountCoordinator?
    private(set) var isAuthenticatingLiveAccount = false
    private(set) var isPromotingSystemAccount = false
    private(set) var userFacingError: CodexSystemAccountPromotionUserFacingError?

    /// Resolves a managed account ID to the name shown to the user. Injected so this model stays UI-free.
    @ObservationIgnored var displayNameResolver: (@MainActor (UUID) -> String?)?
    /// Observes every switch attempt. Wired to the switch island in the app.
    @ObservationIgnored var onSwitchEvent: (@MainActor (CodexAccountSwitchEvent) -> Void)?

    init(
        service: CodexAccountPromotionService,
        managedAccountCoordinator: ManagedCodexAccountCoordinator? = nil)
    {
        self.service = service
        self.managedAccountCoordinator = managedAccountCoordinator
    }

    convenience init(
        settingsStore: SettingsStore,
        usageStore: UsageStore,
        managedAccountCoordinator: ManagedCodexAccountCoordinator? = nil)
    {
        self.init(
            service: CodexAccountPromotionService(settingsStore: settingsStore, usageStore: usageStore),
            managedAccountCoordinator: managedAccountCoordinator)
    }

    func promote(managedAccountID: UUID, trigger: CodexAccountSwitchTrigger = .manual)
        async -> Result<CodexAccountPromotionResult, CodexSystemAccountPromotionUserFacingError>
    {
        self.userFacingError = nil

        guard !self.isInteractionBlocked() else {
            let error = Self.interactionBlockedError()
            self.userFacingError = error
            return .failure(error)
        }

        // Resolved once up front: after the swap the target holds the live slot, so its row may be reshaped.
        let targetDisplayName = self.displayNameResolver?(managedAccountID) ?? ""
        self.isPromotingSystemAccount = true
        self.emit(.began, targetDisplayName: targetDisplayName, trigger: trigger)
        defer { self.isPromotingSystemAccount = false }

        do {
            let result = try await self.service.promoteManagedAccount(id: managedAccountID)
            self.emit(.succeeded, targetDisplayName: targetDisplayName, trigger: trigger)
            return .success(result)
        } catch {
            let mapped = Self.mapUserFacingError(error)
            self.userFacingError = mapped
            self.emit(.failed(message: mapped.message), targetDisplayName: targetDisplayName, trigger: trigger)
            return .failure(mapped)
        }
    }

    private func emit(
        _ kind: CodexAccountSwitchEvent.Kind,
        targetDisplayName: String,
        trigger: CodexAccountSwitchTrigger)
    {
        self.onSwitchEvent?(CodexAccountSwitchEvent(
            targetDisplayName: targetDisplayName,
            trigger: trigger,
            kind: kind))
    }

    func clearError() {
        self.userFacingError = nil
    }

    func setLiveReauthenticationInProgress(_ isInProgress: Bool) {
        self.isAuthenticatingLiveAccount = isInProgress
    }

    func isInteractionBlocked() -> Bool {
        self.isPromotingSystemAccount ||
            self.isAuthenticatingLiveAccount ||
            self.managedAccountCoordinator?.hasConflictingManagedAccountOperationInFlight == true
    }

    private static func interactionBlockedError() -> CodexSystemAccountPromotionUserFacingError {
        CodexSystemAccountPromotionUserFacingError(
            title: L("Could not switch system account"),
            message: L("Finish the current managed account change before switching the system account."))
    }

    static func mapUserFacingError(_ error: Error) -> CodexSystemAccountPromotionUserFacingError {
        let title = L("Could not switch system account")

        if let error = error as? CodexAccountPromotionError {
            let message = switch error {
            case .targetManagedAccountNotFound:
                L("That account is no longer available in CodexBar. Refresh the account list and try again.")
            case .targetManagedAccountAuthMissing:
                L("CodexBar could not find saved auth for that account. Re-authenticate it and try again.")
            case .targetManagedAccountAuthUnreadable:
                L("CodexBar could not read saved auth for that account. Re-authenticate it and try again.")
            case .liveAccountUnreadable:
                L("CodexBar could not read the current system account on this Mac.")
            case .liveAccountMissingIdentityForPreservation:
                L("CodexBar could not safely preserve the current system account before switching.")
            case .liveAccountAPIKeyOnlyUnsupported:
                L("CodexBar can't replace a system account that is signed in with an API key only setup.")
            case .displacedLiveManagedAccountConflict:
                L(
                    "CodexBar found another managed account that already uses the current system account. " +
                        "Resolve the duplicate account before switching.")
            case .displacedLiveImportFailed:
                L("CodexBar could not save the current system account before switching.")
            case .managedStoreCommitFailed:
                L("CodexBar could not update managed account storage.")
            case .liveAuthSwapFailed:
                L("CodexBar could not replace the live Codex auth on this Mac.")
            }

            return CodexSystemAccountPromotionUserFacingError(title: title, message: message)
        }

        return CodexSystemAccountPromotionUserFacingError(title: title, message: error.localizedDescription)
    }
}
