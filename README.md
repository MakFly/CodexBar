# CodexBar — automatic Codex account failover

> Switches your Codex account **before** you run out of quota.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](#build-and-test)
[![Swift 6](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

<img src="docs/social.png" alt="CodexBar — every AI coding limit in your menu bar. 69 providers." width="100%" />

CodexBar is a macOS menu bar app that keeps AI coding-provider limits visible and shows when each window resets — Codex, OpenAI, Claude, Cursor, Gemini, Copilot, and many more. One status item per provider, no Dock icon, minimal UI.

This build adds one thing on top: **when your Codex System account runs low, CodexBar promotes a healthier one for you.**

<img src="docs/codexbar.png" alt="CodexBar menu popover with provider tiles, usage bars, and reset countdowns" width="520" />

> Derived from [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT). See [Credits](#credits).

---

## What this build adds

### 1. Opt-in automatic system-account failover

When the System account's remaining quota drops to a configurable threshold on the tighter of its 5-hour and weekly windows, CodexBar promotes the healthiest added account into the System slot — through the same promotion path a manual switch uses, so the displaced account is preserved first.

```
 multi-account refresh commits
             │
             ▼
   ┌───────────────────────┐   no    ┌──────────────┐
   │ failover enabled?     ├────────►│ do nothing   │
   │ 2+ accounts?          │         └──────────────┘
   └──────────┬────────────┘
              │ yes
              ▼
   ┌───────────────────────────────────────────┐
   │ CodexAccountFailoverPolicy  (pure)        │
   │  · System account at or below threshold?  │
   │  · candidates: managed, healthy, above it │
   │  · pick max headroom, deterministic tie   │
   └──────────┬────────────────────────────────┘
              │ decision
              ▼
   ┌───────────────────────────────────────────┐
   │ AutoFailoverCoordinator  (guards)         │
   │  · 10 min cooldown   · in-flight ops      │
   │  · re-entrancy       · setting still on   │
   └──────────┬────────────────────────────────┘
              │ promote
              ▼
   ┌───────────────────────────────────────────┐
   │ CodexAccountPromotionCoordinator.promote  │  ← single choke point
   │  writes CODEX_HOME/auth.json              │     (menu · settings · auto)
   └──────────┬────────────────────────────────┘
              │
       ┌──────┴──────┐
       ▼             ▼
  switch island   notification
  (on screen)     (names both accounts)
```

**Off by default.** The toggle appears in *Settings → Providers → Codex* once you have two or more accounts. Enabling it forces the multi-account fetch in any menu layout, since the policy needs every account's headroom.

| Setting | Key | Values | Default |
|---|---|---|---|
| Automatically switch the system account | `codexAutoFailoverEnabled` | `true` / `false` | `false` |
| Switch when the System account has at most | `codexAutoFailoverThresholdPercent` | `5`, `10`, `20`, `30` | `10` |

Both live under the Codex provider entry in `~/.config/codexbar/config.json`.

### 2. A switch island

Every System-account swap surfaces a click-through island on screen — a spinner while the promotion runs, then a green check naming the account Codex now uses, or the user-facing error. It is driven from the promotion choke point, so the menu submenu, the Accounts settings picker, and automatic failover all report through it; the automatic case says the quota was reached.

```
   ┌─────────────────────────────────┐
   │  ⣾  Switching to work@acme.com  │   blue    · in flight
   ├─────────────────────────────────┤
   │  ✓  Codex now uses work@acme    │   green   · held 4.5s
   ├─────────────────────────────────┤
   │  ⚠  Could not switch account    │   orange  · error text
   └─────────────────────────────────┘
```

It places itself clear of the notch-utility reserve. Notch widgets (Perch and friends) pin a fixed transparent canvas under the cutout — 704×670pt at `.statusBar + 2`, far larger than what they paint at rest — above our window level. A centred island sat *behind* that panel and read as the other app breaking. `CodexAccountSwitchIslandPlacement` keeps it to the side of a 704pt reserved centre, narrows it to the room available, and drops it to the bottom of the screen only when no readable width is left.

---

## System account vs. display switcher

This distinction is the reason the feature works, and it is easy to get wrong:

| | What it controls |
|---|---|
| **System account** | The credentials in `CODEX_HOME/auth.json` — what the **Codex CLI and app actually use**. |
| **Menu switcher** | **Display only.** Which account CodexBar shows you. Changing it does not touch your credentials. |

Failover keys on the *System* account. An earlier iteration keyed on the displayed one, which meant selecting a drained account merely to look at it could swap your real credentials — and a drained System account was ignored while you happened to be viewing another. That is precisely the case the feature exists for.

The System account is also pinned inside the per-refresh account cap, so its headroom stays known even past `tokenAccountMenuSnapshotLimit`.

---

## Source map

| File | Role |
|---|---|
| `CodexAccountFailoverPolicy.swift` | Pure decision: eligibility, threshold, max headroom, tie-break. |
| `CodexAccountAutoFailoverCoordinator.swift` | Listens to refresh commits, applies guards, posts the notification. |
| `CodexAccountSwitchIslandState.swift` | Generation-guarded phase machine, bounded spinner, short-lived outcomes. |
| `CodexAccountSwitchIslandController.swift` | Borderless non-activating panel. |
| `CodexAccountSwitchIslandPlacement.swift` | Pure placement resolver that avoids the notch band. |
| `CodexAccountPromotionCoordinator.swift` | The single promotion choke point; emits `CodexAccountSwitchEvent`. |

Covered by 25 tests across `CodexAccountFailoverPolicyTests` (8), `CodexAccountAutoFailoverCoordinatorTests` (7), and `CodexAccountSwitchIslandTests` (10). Strings are localized in every shipped locale.

---

## Docs

- [Codex provider](docs/codex.md) — accounts, the System slot, and the failover section.
- [Codex OAuth](docs/codex-oauth.md) — how credentials are read and refreshed.
- [Architecture](docs/architecture.md) — how providers, stores, and the status item fit together.
- [Providers](docs/providers.md) — every supported provider and its data source.
- [Releasing](docs/RELEASING.md) — packaging, signing, and notarization.

---

## Build and test

```bash
swift build                # debug
make test                  # full sharded suite
make check                 # swiftformat + swiftlint --strict
./Scripts/compile_and_run.sh   # build, package, relaunch the bundle
```

> **Known locale failure:** `MiniMaxMenuCardBillingTests` fails on non-`en_US` machines — it expects `"1,234"` while a French locale renders `"1 234"`. Inherited from the original codebase, unrelated to the failover work.

## Pulling in changes from the original project

This repository was reinitialized with a fresh history, so it shares no commits with `steipete/CodexBar` and cannot merge from it directly. To port a later upstream change, apply it as a patch:

```bash
git remote add upstream https://github.com/steipete/CodexBar.git
git fetch upstream
git diff <old>..<new> -- <paths> | git apply    # or: git cherry-pick -n <sha>
```

The Codex failover files listed above are additions, so upstream changes rarely touch them. Watch `CodexAccountPromotionCoordinator.swift` in particular — it is the seam the failover hooks into.

## Install

No releases are published here. Build from source with the commands above, or install the original CodexBar from [its releases](https://github.com/steipete/CodexBar/releases) if you do not need failover.

## Credits

CodexBar is [Peter Steinberger](https://github.com/steipete)'s work and its contributors', released under MIT. This repository is a derivative that adds the Codex failover path described above.

## License

MIT — see [LICENSE](LICENSE).
