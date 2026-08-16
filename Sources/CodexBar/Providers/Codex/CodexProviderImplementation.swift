import CodexBarCore
import Foundation
import SwiftUI

struct CodexProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .codex
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.version(for: context.provider) ?? "not detected"
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.codexUsageDataSource
        _ = settings.codexCookieSource
        _ = settings.codexCookieHeader
        _ = settings.codexExternalOAuthSourcesAllowed
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .codex(context.settings.codexSettingsSnapshot(
            tokenOverride: context.tokenOverride,
            activeSourceOverride: context.codexActiveSourceOverride))
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.codexUsageDataSource.rawValue
    }

    @MainActor
    func decorateSourceLabel(context: ProviderSourceLabelContext, baseLabel: String) -> String {
        if context.settings.codexCookieSource.isEnabled,
           context.store.openAIDashboard != nil,
           !context.store.openAIDashboardRequiresLogin,
           !baseLabel.contains("openai-web")
        {
            return "\(baseLabel) + openai-web"
        }
        return baseLabel
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.codexUsageDataSource {
        case .auto: .auto
        case .oauth: .oauth
        case .cli: .cli
        }
    }

    func makeRuntime() -> (any ProviderRuntime)? {
        CodexProviderRuntime()
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        let extrasBinding = Binding(
            get: { context.settings.openAIWebAccessEnabled },
            set: { enabled in
                context.settings.openAIWebAccessEnabled = enabled
                Task { @MainActor in
                    await context.store.performRuntimeAction(
                        .openAIWebAccessToggled(enabled),
                        for: .codex)
                }
            })
        let batterySaverBinding = context.boolBinding(\.openAIWebBatterySaverEnabled)
        let historicalTrackingSubtitle = [
            L("Stores local Codex usage history (8 weeks) to personalize Pace predictions."),
            "[\(L("weekly_progress_work_days_title")) = \(L("Automatic"))]",
        ].joined(separator: " ")

        let autoFailoverStatus: () -> String? = {
            let projection = context.settings.codexVisibleAccountProjection
            let managedCandidates = projection.visibleAccounts.filter { $0.storedAccountID != nil && !$0.isLive }
            guard managedCandidates.isEmpty else {
                // Name the account that would actually be replaced, so this is never confused with the
                // menu switcher's display-only selection.
                guard let systemAccount = projection.visibleAccounts
                    .first(where: { $0.id == projection.liveVisibleAccountID })
                else {
                    return nil
                }
                return String(format: L("codex_auto_failover_current_system_account"), systemAccount.displayName)
            }
            return L("Add at least one more Codex account to enable switching.")
        }

        return [
            ProviderSettingsToggleDescriptor(
                id: "codex-auto-failover",
                title: "Automatically switch the system account",
                subtitle: [
                    "When the System account runs down to the threshold on its 5-hour or weekly limit,",
                    "CodexBar promotes the healthiest added account into the System slot —",
                    "the same swap as the System Account menu, so the Codex CLI and app follow.",
                    "Selecting an account in the menu switcher only changes what is displayed and never triggers this.",
                    "Off by default; never switches while another account change is in progress.",
                ].joined(separator: " "),
                binding: context.boolBinding(\.codexAutoFailoverEnabled),
                statusText: autoFailoverStatus,
                actions: [],
                isVisible: { context.settings.codexVisibleAccountProjection.visibleAccounts.count > 1 },
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-local-session-cost-ledger",
                title: "Local session cost estimates",
                subtitle: [
                    "Uses this Mac's Codex sessions instead of the selected managed account's session history.",
                    "Works with organization API keys and does not require OpenAI billing or administrator access.",
                    "Uses locally cached or bundled model prices without making a network request.",
                    "This provider-specific toggle does not enable cost summaries for other providers.",
                ].joined(separator: " "),
                binding: context.boolBinding(\.codexLocalSessionCostLedgerEnabled),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-historical-tracking",
                title: "Historical tracking",
                subtitle: historicalTrackingSubtitle,
                binding: context.boolBinding(\.historicalTrackingEnabled),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-spark-usage-visible",
                title: "Show Codex Spark usage",
                subtitle: [
                    "Shows Codex Spark quota rows in the menu and provider preview.",
                    "Requires optional credits and extra usage in Display settings.",
                ].joined(separator: " "),
                binding: context.boolBinding(\.codexSparkUsageVisible),
                statusText: nil,
                actions: [],
                isVisible: nil,
                isEnabled: { context.settings.showOptionalCreditsAndExtraUsage },
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-openai-web-extras",
                title: "OpenAI web extras",
                subtitle: [
                    "Optional.",
                    "Turn this on to show code review, usage breakdown, and credits history via chatgpt.com.",
                ].joined(separator: " "),
                binding: extrasBinding,
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-external-oauth-sources",
                title: "External Codex OAuth sources",
                subtitle: [
                    "Explicitly allow read-only fallback to legacy Codex and OpenCode OAuth files.",
                    "CodexBar never refreshes or writes those external credentials.",
                    "Off by default because this shares another app's OAuth session with Codex usage requests.",
                ].joined(separator: " "),
                binding: context.boolBinding(\.codexExternalOAuthSourcesAllowed),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-openai-web-battery-saver",
                title: "OpenAI web battery saver",
                subtitle: [
                    "Limits background chatgpt.com refreshes to reduce battery and network usage.",
                    "Dashboard extras may stay stale until you refresh them manually.",
                ].joined(separator: " "),
                binding: batterySaverBinding,
                statusText: nil,
                actions: [],
                isVisible: { context.settings.openAIWebAccessEnabled },
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.codexUsageDataSource.rawValue },
            set: { raw in
                context.settings.codexUsageDataSource = CodexUsageDataSource(rawValue: raw) ?? .auto
            })
        let cookieBinding = Binding(
            get: { context.settings.codexCookieSource.rawValue },
            set: { raw in
                context.settings.codexCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })

        let usageOptions = CodexUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.codexCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies for dashboard extras.",
                manual: "Paste a Cookie header from a chatgpt.com request.",
                off: "Disable OpenAI dashboard cookie usage.")
        }

        let failoverThresholdBinding = Binding(
            get: { String(context.settings.codexAutoFailoverThresholdPercent) },
            set: { raw in
                context.settings.codexAutoFailoverThresholdPercent = Int(raw)
                    ?? SettingsStore.codexAutoFailoverDefaultThresholdPercent
            })
        let failoverThresholdOptions = SettingsStore.codexAutoFailoverThresholdChoices.map {
            ProviderSettingsPickerOption(id: String($0), title: "\($0)%")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "codex-auto-failover-threshold",
                title: "Switch when the System account has at most",
                subtitle: "Remaining quota on the tighter of its 5-hour and weekly windows.",
                binding: failoverThresholdBinding,
                options: failoverThresholdOptions,
                isVisible: {
                    context.settings.codexAutoFailoverEnabled &&
                        context.settings.codexVisibleAccountProjection.visibleAccounts.count > 1
                },
                onChange: nil,
                trailingText: nil),
            ProviderSettingsPickerDescriptor(
                id: "codex-usage-source",
                title: "Quota usage source",
                subtitle: [
                    "Controls live session and weekly quota fetching only.",
                    "Local session cost estimates work independently.",
                ].joined(separator: " "),
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.codexUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .codex)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "codex-cookie-source",
                title: "OpenAI cookies",
                subtitle: "Automatic imports browser cookies for dashboard extras.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: { context.settings.openAIWebAccessEnabled },
                onChange: nil,
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .codex)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "codex-cookie-header",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.codexCookieHeader),
                actions: [],
                isVisible: {
                    context.settings.codexCookieSource == .manual
                },
                onActivate: { context.settings.ensureCodexCookieLoaded() }),
        ]
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard context.settings.showOptionalCreditsAndExtraUsage,
              context.metadata.supportsCredits
        else { return }

        if let credits = context.store.credits {
            let remaining = credits.codexCreditLimit?.remaining ?? credits.remaining
            entries.append(.text(
                String(format: L("credits_remaining"), UsageFormatter.creditsString(from: remaining)),
                .primary))
            if let limit = credits.codexCreditLimit {
                var parts = [
                    L("%@ used", UsageFormatter.creditsNumberString(from: limit.used)),
                ]
                if let resetsAt = limit.resetsAt {
                    parts.append(L("resets %@", UsageFormatter.resetDescription(from: resetsAt)))
                }
                entries.append(.text(parts.joined(separator: " · "), .secondary))
            }
            if let latest = credits.events.first {
                entries.append(.text(
                    String(format: L("last_spend"), UsageFormatter.creditEventSummary(latest)),
                    .secondary))
            }
        } else {
            let hint = context.store.userFacingLastCreditsError ?? context.metadata.creditsHint
            entries.append(.text(hint, .secondary))
        }
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        ("Add Account...", .addCodexAccount)
    }

    @MainActor
    func appendActionMenuEntries(context: ProviderMenuActionContext, entries: inout [ProviderMenuEntry]) {
        let projection = context.settings.codexVisibleAccountProjection
        guard !projection.visibleAccounts.isEmpty else { return }

        let isInteractionBlocked = context.codexAccountPromotionCoordinator?.isInteractionBlocked() ?? false

        let submenuItems = projection.visibleAccounts.map { account in
            let isChecked = account.id == projection.liveVisibleAccountID
            let isEnabled = !isInteractionBlocked &&
                !isChecked &&
                account.storedAccountID != nil
            let action = account.storedAccountID.map(MenuDescriptor.MenuAction.requestCodexSystemPromotion)
            return MenuDescriptor.SubmenuItem(
                title: account.displayName,
                action: action,
                isEnabled: isEnabled,
                isChecked: isChecked)
        }
        guard submenuItems.count > 1 || submenuItems.contains(where: { $0.isEnabled && $0.action != nil }) else {
            return
        }

        entries.append(.submenu(
            "System Account",
            MenuDescriptor.MenuActionSystemImage.systemAccount.rawValue,
            submenuItems))
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runCodexLoginFlow()
        return true
    }
}
