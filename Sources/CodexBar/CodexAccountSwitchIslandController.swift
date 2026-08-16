import AppKit
import CodexBarCore
import SwiftUI

/// Presents a transient "island" under the notch while the Codex **system** account is being swapped, then
/// reports the outcome.
///
/// Modeled after ``QuotaWarningAlertOverlayController``: a borderless, click-through panel above all spaces that
/// never steals focus. It is driven from ``CodexAccountPromotionCoordinator``, so it covers every switch — the
/// menu's System Account submenu, the Accounts settings picker, and automatic failover.
@MainActor
final class CodexAccountSwitchIslandController {
    private let logger = CodexBarLog.logger("codex-account-switch-island")
    private var presentationState = CodexAccountSwitchIslandState()
    private var window: NSWindow?
    private var dismissalTask: Task<Void, Never>?

    /// Begins (or replaces) an island for a switch that just started.
    func begin(target: String, trigger: CodexAccountSwitchTrigger) {
        self.show(self.presentationState.present(.switching(target: target, trigger: trigger)))
    }

    /// Reports the outcome of the in-flight switch. Ignored when no island is on screen.
    func resolve(succeeded target: String, trigger: CodexAccountSwitchTrigger) {
        guard let presentation = self.presentationState.resolve(.succeeded(target: target, trigger: trigger)) else {
            return
        }
        self.show(presentation)
    }

    func resolve(failed message: String, trigger: CodexAccountSwitchTrigger) {
        guard let presentation = self.presentationState.resolve(.failed(message: message, trigger: trigger)) else {
            return
        }
        self.show(presentation)
    }

    func dismiss() {
        self.dismissalTask?.cancel()
        self.dismissalTask = nil
        self.presentationState.dismiss()
        self.closeWindow()
    }

    private func show(_ presentation: CodexAccountSwitchIslandState.Presentation) {
        self.dismissalTask?.cancel()
        self.dismissalTask = nil

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            self.logger.error("Cannot present the account switch island because no screens were found")
            self.presentationState.dismiss()
            return
        }

        let frame = screen.frame
        let contentView = CodexAccountSwitchIslandView(
            phase: presentation.phase,
            placement: CodexAccountSwitchIslandPlacement.resolve(screenWidth: frame.width),
            topInset: Self.topInset(for: screen))
            .allowsHitTesting(false)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let window = self.window ?? Self.makeWindow(screen: screen, frame: frame)
        window.contentView = hostingView
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        self.window = window

        self.dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(presentation.lifetime))
            guard !Task.isCancelled else { return }
            guard let self, self.presentationState.dismiss(generation: presentation.generation) else { return }
            self.closeWindow()
        }
    }

    /// Clears the notch, or the menu bar on displays without one.
    private static func topInset(for screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) + 8
    }

    private static func makeWindow(screen: NSScreen, frame: NSRect) -> NSWindow {
        let window = ClickThroughIslandPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.canHide = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isExcludedFromWindowsMenu = true
        return window
    }

    private func closeWindow() {
        guard let window = self.window else { return }
        window.orderOut(nil)
        window.close()
        self.window = nil
    }
}

private final class ClickThroughIslandPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

struct CodexAccountSwitchIslandView: View {
    let phase: CodexAccountSwitchIslandState.Phase
    var placement = CodexAccountSwitchIslandPlacement.resolve(screenWidth: 1512)
    var topInset: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 12) {
            self.leadingIcon
            Text(self.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: self.placement.maxWidth)
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        // Saturated fill rather than the usual material: this has to read at a glance against a busy menu bar
        // and next to third-party notch widgets.
        .background(self.tint.gradient, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.24), lineWidth: 1))
        .shadow(color: self.tint.opacity(0.45), radius: 20, y: 6)
        .shadow(color: .black.opacity(0.32), radius: 28, y: 12)
        .scaleEffect(self.reduceMotion || self.appeared ? 1 : 0.86)
        .offset(y: self.reduceMotion || self.appeared ? 0 : self.entryOffset)
        .opacity(self.reduceMotion || self.appeared ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: self.alignment)
        .padding(.top, self.placement.anchor == .topTrailing ? self.topInset : 0)
        .padding(.bottom, self.placement.anchor == .bottomCenter ? 64 : 0)
        .padding(.horizontal, CodexAccountSwitchIslandPlacement.screenMargin)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.title)
        .task {
            guard !self.reduceMotion else {
                self.appeared = true
                return
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                self.appeared = true
            }
        }
    }

    private var alignment: Alignment {
        switch self.placement.anchor {
        case .topTrailing:
            .topTrailing
        case .bottomCenter:
            .bottom
        }
    }

    private var entryOffset: CGFloat {
        switch self.placement.anchor {
        case .topTrailing:
            -18
        case .bottomCenter:
            18
        }
    }

    var tint: Color {
        Self.tint(for: self.phase)
    }

    /// One saturated colour per phase, so the outcome is readable before the text is.
    static func tint(for phase: CodexAccountSwitchIslandState.Phase) -> Color {
        switch phase {
        case .switching:
            Color(nsColor: .systemBlue)
        case .succeeded:
            Color(nsColor: .systemGreen)
        case .failed:
            Color(nsColor: .systemOrange)
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch self.phase {
        case .switching:
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
                .tint(.white)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    var title: String {
        Self.title(for: self.phase)
    }

    /// Pure text mapping so the wording stays testable without building the view.
    static func title(for phase: CodexAccountSwitchIslandState.Phase) -> String {
        switch phase {
        case let .switching(target, trigger):
            switch trigger {
            case .manual:
                String(format: L("codex_switch_island_switching"), target)
            case .automaticFailover:
                String(format: L("codex_switch_island_switching_automatic"), target)
            }
        case let .succeeded(target, _):
            String(format: L("codex_switch_island_succeeded"), target)
        case let .failed(message, _):
            message
        }
    }
}
