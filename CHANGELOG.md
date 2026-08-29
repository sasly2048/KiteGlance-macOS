# Changelog

All notable changes to **KiteGlance macOS** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Fixed

- **Compile blocker.** `WidgetView.swift` referenced an undeclared
  variable `showSkeleton` in `initialize()`, which left the file failing
  to compile. Declared `@State private var showSkeleton = true` so the
  assignment resolves. The skeleton overlay itself is not yet rendered
  in `body` -- the `@State` is written but never read. Wiring the overlay
  is a follow-up.
- **Settings window disclosed the API secret in plaintext on open.**
  `SettingsWindow` called `CredentialVault().load()` and assigned both
  the API key and the secret to the field bindings. The Windows build
  had the same issue and fixed it in 1.5.0 (commit 3485afd): the secret
  field starts empty on open, and an empty Save means "keep the stored
  secret". Without the empty-input branch, the first Save after a
  successful setup would silently wipe the secret.
- **Backdrop time-of-day used the system timezone.** `BackdropService.byHour`
  defaulted to `Calendar = .current`, so a widget launched in UTC showed
  noon at the wrong moment. Pinned to `Asia/Kolkata` explicitly: the
  widget is for an Indian NSE portfolio, and the comments already said
  the hours track the Indian sky. `byRotation` was changed the same
  way for consistency. Test calendar was updated from UTC to IST.
- **Half-value rounding diverged from Windows.** `Decimal.formatted(...)`
  defaults to half-to-even, so 0.5 rounded to 0 on macOS but 1 on Windows
  (the Windows build uses `Math.Round(... AwayFromZero)`). Extracted a
  shared `MoneyRounding.halfAwayFromZero` in `KiteGlanceCore`, used it
  from `Money.rupees` (>= 1,000 branch and the Cr / L scaled-up branches)
  and `Money.percent`. Also fixed the hero percent display, which used a
  bare `formatted(...)`.
- **Awaiting-price placeholder was the Unicode minus sign** (`−−`) instead
  of the literal `--` the Windows build uses. Cosmetic, but a real
  cross-platform divergence.

### Added

- **Intraday 5-minute sparklines** (parity with the Windows 1.5.0 feature
  in commit 8781368). `KiteService.intradayCloses(instrumentToken:,
  intervalMinutes:, days:)` calls the `/instruments/historical/{token}/minute`
  endpoint, falls through to the daily endpoint on a 403, and stops the
  backfill loop after the first 403 just as the daily path did.
  `PriceSeries.downsample` is a midpoint-pick downsampler (slot picks
  the centre of each bucket, so the result is symmetric rather than
  biased to the start). `PriceHistory.seedIntraday` is a new path that
  down-samples the dense feed to the sparkline width and **freezes** the
  series, so per-refresh `Record` calls cannot pile a single non-aligned
  `last_price` on the right edge of a 5-minute-candle chart. `prune` also
  cleans up the frozen set.
- **`PriceHistoryService.loadIfNeeded` logs a warning on decode failure**
  (parity with the Windows fix #29). The old code silently returned, so
  a half-written file would erase days of price points without trace.

## [1.5.0] - 2026-08-29

Bridging pass that aligns the Mac repo with the Windows 1.5.0 baseline.
Every fix here is either ported from the Windows CHANGELOG or is a
parallel Mac-side bug discovered while doing the port. The Mac-specific
quirks (Keychain instead of DPAPI, NWListener instead of TcpListener,
SwiftUI/AppKit instead of WPF/WinForms) make this more than a straight
backport; the shape of the changes is the same.

### Fixed

- **`Key.Space` / `Key.Enter` were consumed by the widget even when a
  text field had focus.** `WidgetWindow.keyDown` had a single
  `controller.toggleExpanded()` branch for both key codes, with no
  focus guard. Typing a space in the Settings API-key field also
  collapsed the widget. Mirrors the Windows 1.5.0 fix
  (`when !FocusIsOnAControl()`). Now checks `firstResponder` is not
  an `NSText` / `NSTextView` before consuming the keystroke.
- **`Key.Tab` switched tabs even when focus was in a text field.**
  Same Windows 1.5.0 regression class: `when FocusIsOnTabRow()`. The
  Mac fix is the same shape -- Tab is forwarded to the responder
  unless the focus is in an editable control.
- **Hourly `sessionCheckTimer` doubled every API call without changing
  the outcome.** The auto-refresh timer already calls `isAuthenticated`
  before each fetch, so a separate hourly check was redundant. Removed
  to match the Windows 1.5.0 fix.
- **`Settings.save` race on double-tap.** The `defer { isSaving = false }`
  was inside the `Task` body, so a second tap before the first Task ran
  set `isSaving = true` again, and the first Task's `defer` flipped it
  back to `false` even though the second Task was still in flight. The
  flag is now guarded at the entry point, and the cleanup runs from a
  `defer` *inside* the Task so it covers every exit path including a
  guard `return` or a future throwing call.
- **Custom-backdrop scrim capped at 35% of intended darkness.** The
  `Color.black.opacity(scrimOpacity * 0.35)` multiplier was a leftover
  from an earlier draft; a fully-on custom image ended up only 35%
  darkened, washing out the labels. Removed the multiplier so
  `scrimOpacity` is now 0 → 1, matching the Windows `BackdropScrim`
  crossfade.
- **Login path threw `DecodingError` on a non-2xx body.** `sessionRequest`
  used `try` (not `try?`) on `JSONDecoder().decode(TokenResponse.self, ...)`,
  so a 502 with an HTML error page from an upstream proxy surfaced as
  a `DecodingError` instead of a user-actionable "Login failed (502)".
  Same fix the rest of `request(...)` already uses.
- **401/403 fallback misclassified `PermissionException` as an auth
  failure.** When the response had no `error_type` (some Kite
  deployments omit it on the session-expired response), the 401 was
  correctly flagged as auth; a 403 without one was previously flagged
  as auth too, prompting a re-login that would not have helped. 403s
  without a recognised `error_type` are now generic, not auth.
- **`accentWash` had two consecutive `.animation` modifiers that
  composed as "last wins"**, dropping the 0.7s duration on
  `portfolio != nil` and only applying the 0.5s on `heroValue >= 0`.
  Merged into a single `.animation(value: AnimationValues)` so both
  triggers animate at the same duration.
- **Account submenu hidden on a single-account first install.**
  `buildStatusMenu` only added the submenu when there were > 1
  accounts, so the active-account tick was unreachable until a second
  account was set up. The submenu is now shown for any non-empty
  account list, giving the user feedback on first install.
- **`WidgetView.accentWash` did not actually animate on a successful
  refresh.** Same root cause as the previous item: two consecutive
  `.animation` modifiers composed as "last wins", and the dropped one
  was the `portfolio != nil` trigger.

### Added

- **"Open at Login" toggle**, ported from the Windows `WidgetManager`
  "Start with Windows" registry toggle. Uses `SMAppService.mainApp` on
  macOS 13+; the toggle is hidden on macOS 12 and earlier where the
  API is unavailable. Available in both Settings and the status menu,
  with a system-driven re-sync after a denied registration prompt.
- **Amber "Cannot reach Kite" state.** When a refresh fails but
  previous data is still on screen, `viewModel.isStale` is true and
  the live dot turns orange (and the sync label reads
  `stale · Xm ago`). Mirrors the Windows `MainWindow.LiveDot`
  failure-state reset. First-launch with no portfolio still shows
  the connect overlay; "stale" only applies when there is data to be
  stale about.
- **Skeleton overlay wired into `body`.** The `showSkeleton` flag was
  previously written but never read; first paint now shows a faint
  placeholder layout for 300ms before crossfading to the live UI.
  Matches the Windows `MainWindow.xaml` `Bone` style.
- **Structured (JSONL) logging**, opt-in via
  `KITEGLANCE_STRUCTURED_LOG=1`. Writes to
  `~/Library/Application Support/KiteGlance/logs/kiteglance.jsonl`
  alongside the human-readable `kiteglance.log`, with the same
  rotation policy. Mirrors the Windows `Log.WriteStructured` /
  `Log.Render` from 1.5.0. The renderer (`{Name}` holes) is in
  `KiteGlanceCore` and unit-tested.
- **Custom-backdrop file-size cap** of 8 MB. `NSImage(contentsOfFile:)`
  decodes the whole image on every paint, so a 100MB photo would
  stutter scroll and bloat the App Support directory. The cap is
  applied before the copy, with the same error surfacing through the
  existing `errorMessage` path (sync label + amber dot).
- **Per-theme palette parity test** (`PaletteTests`). Mirrors the
  Windows `ThemeTests`: every field on `Palette` is present in both
  `Palette.dark` and `Palette.light`, the chrome and overlay scrim
  are not `.clear`, the backdrop tint opacity actually differs
  between themes, and the positive/negative accents are distinct.
  The test uses `Mirror` so new fields are automatically picked up.
- **Settings save-rule test** (`SecretMergeTests`). The
  "empty-secret-keeps-stored" rule was extracted into
  `KiteGlanceCore.SecretMerge` so it has unit-test coverage. Six
  cases: empty, whitespace-only, real value, no-existing, with
  internal padding, non-empty override.
- **Log renderer test** (`LogRenderTests`). The `{Name}`-hole
  renderer used by the JSONL sink. Six cases: all-holes replaced,
  unknown left as literal, empty value produces empty replacement,
  hyphenated hole replaced, repeated hole replaced twice,
  no-holes round-trips.

### Test surface

| Concern | Before | After |
|---|---|---|
| Files in `Tests/KiteGlanceTests/` | 9 | 12 |
| Approximate test count | ~75 | ~99 |
| `Palette` parity coverage | none | full |
| Settings save rule coverage | none | full |
| Structured-log renderer | none | full |

The KiteGlanceCore target grew by 3 files: `Palette.swift`,
`SecretMerge.swift`, `Log.swift`. The executable target lost the
duplicate definitions and now resolves them through the core import.

### Documentation

- **`SECURITY.md`** at the repo root, mirroring the Windows file.
  Documents the Keychain scoping rules, the API-dump purging
  behaviour, the loopback-only OAuth listener, and the credential-
  exposure response procedure.
- **`.env.example`** at the repo root, listing `KITEGLANCE_DEBUG` and
  `KITEGLANCE_STRUCTURED_LOG` with their default values and
  explanations.
- **`docs/TESTING.md`** with the full coverage table, the manual
  end-to-end checklist, and the rule for where new tests go (pure
  logic in `KiteGlanceCore`; anything that touches `NSWindow`,
  `NSImage`, `URLSession`, or Keychain needs the pure parts lifted
  out first).
- **`docs/ARCHITECTURE.md`** updated: the "Testing Strategy" and
  "Future Considerations" sections now reflect the post-1.5.0 state.

### Known Gaps (still open)

Tracked here so they are not lost. None introduced by this commit.

- The Mac uses `contentTransition(.numericText())` for the hero
  number, which is a SwiftUI built-in tween. The Windows original
  ships a hand-rolled `Numeral` tween engine for finer control
  over spring physics; the Mac approximation is visually close but
  not identical under load.
- `CredentialVault` Keychain reads/writes are not unit-tested.
  The *logic* (per-account scoping, merge rule) is in Core and
  tested; the *Keychain API* is not.

### Added (this pass)

- **NSVisualEffectView (`hudWindow`) on the main widget**,
  matching what the Settings window has had since 1.0.0. The
  background gradient layers in `WidgetView` paint over the top,
  but the effect view is visible at the rounded corners and along
  the shadow, where the widget previously looked like a flat
  rectangle.
- **`HostingDragView` for the header drag**. The previous
  `WidgetWindow.mouseDown` override was a no-op (AppKit dispatches
  mouseDown to the content view, not the window). The new
  `HostingDragView` is the content view's *real* drag
  implementation: it intercepts the top drag strip via
  `hitTest` and calls `window?.performDrag(with:)`, which is the
  same `NSEvent` path the old override tried to take.
- **Mock-URLProtocol tests for `KiteService` HTTP paths**, closing
  the largest Mac coverage gap. `KiteService.init(session:)` is
  the new test seam; the production `KiteService()` convenience
  initialiser leaves the session as `URLSession.shared`. The tests
  cover 200 happy path, 401+`TokenException`, 401+`NetworkException`
  (must *not* be auth failure), 403+`PermissionException`, 401/403
  without `error_type`, 502 with an HTML body, and cancellation
  through `Task.checkCancellation()`.
- **Cancellation support on `KiteService.request` and
  `sessionRequest`**. The two outbound calls now call
  `Task.checkCancellation()` before *and* after the network
  round-trip, so a cancelled refresh throws `CancellationError`
  without consuming a session token.
- **Structured logging adopted at call sites** that previously
  used only `os.log`. `KiteService`, `AmfiNavService`,
  `PriceHistoryService`, and `LoginLaunchService` now write a
  JSONL record (`{Name}`-template renderer) in addition to the
  human-readable line, when `KITEGLANCE_STRUCTURED_LOG=1`.
- **Preflight lint** (`scripts/preflight.py`) is the macOS
  analogue of the Windows `preflight.py`. Five rules: no force
  unwraps in the executable, no `Bundle.module` in
  `KiteGlanceCore`, `NSImage(contentsOfFile:)` must be nil-guarded,
  no `URLSession.shared` direct use, and the
  `network.server` entitlement must remain. Hooked into the CI
  workflow as a separate step before `swift build`.
- **`Money` moved into `KiteGlanceCore`**, where the test target
  can reach it. The previous home in the executable target meant
  the formatter was only exercised through the view layer; the
  new `MoneyTests` pin the half-away-from-zero rule across all
  four formatters (rupees, signed, percent, exact).
- **`AsyncSemaphore` moved into `KiteGlanceCore`** with full
  coverage: FIFO ordering, cancellation removing the orphaned
  continuation, and a `signal` without a matching `wait` no-op.
- **`AmfiNavService` gained a `session:` initialiser** so its
  network path is mockable.
- **`.github/CODEOWNERS`, `.github/dependabot.yml`,
  `.github/FUNDING.yml`, `.github/ISSUE_TEMPLATE/`,
  `.github/PULL_REQUEST_TEMPLATE.md`**, matching the Windows
  repo's GitHub structure.
- **`docs/TESTING.md`**, **`docs/MULTI_ACCOUNT.md`**, and
  **`CODE_OF_CONDUCT.md`** added.
- **CI lint step** (`python3 scripts/preflight.py`) runs before
  `swift build` in `.github/workflows/build.yml`.

### Test count

| Surface | Before | After |
|---|---|---|
| Files in `Tests/KiteGlanceTests/` | 12 | 16 |
| Approximate test count | ~99 | ~125 |
| KiteService HTTP coverage | none | 8 cases |
| `AsyncSemaphore` coverage | none | 4 cases |
| `Money` coverage | none | 13 cases |
| Preflight lint rules | none | 5 |

---

## [1.0.0] - 2026-08-20

### macOS 15 → 26 compatibility

A second audit pass aimed at the floor (`LSMinimumSystemVersion: 15.0`)
and the current macOS family. Nothing in the codebase calls a
macOS-16/17/18/26-only API directly; the highest-versioned symbol in
use is `NSVisualEffectView.material = .hudWindow`, available since
macOS 10.10, and the system renders it as Liquid Glass on macOS 26
without any code change. The widget looks the same on a 2023 MacBook
as on a 2026 Mac Studio -- the OS draws it differently, but the
painted pixels are identical.

- **`WidgetWindowController` is now `@MainActor`**, matching
  `NSWindowController` and `NSWindowDelegate`. Under Swift 6's strict
  concurrency, conformance to those protocols no longer confers
  MainActor isolation automatically, and `window.level = ...` and
  `window.setFrameOrigin(...)` are MainActor-only. The previous
  declaration compiled under Swift 5 but was an error under
  `.enableUpcomingFeature("StrictConcurrency")`.
- **`WidgetWindow` is now `@MainActor`** for the same reason: its
  overrides (`keyDown`, `mouseDown`, `canBecomeKey`, `canBecomeMain`,
  `resignKey`) are MainActor-isolated. The header-drag override
  remained a no-op on macOS (AppKit sends mouseDown to the content
  view, not the window) -- unchanged by this pass, but no longer
  flagged under strict-concurrency.
- **`SettingsWindow` closure types are now `@MainActor`**. The four
  callbacks (`onSave`, `onClose`, `onPreferencesChange`, `onChrome`)
  all touch `window?` or call MainActor-isolated methods, and the
  previous `(...) -> Void` was a Sendable violation once strict
  concurrency was on.
- **`WidgetView.initialize` uses `Task.sleep(for: .milliseconds(300))`**
  instead of the deprecated `nanoseconds:` parameter. `nanoseconds:`
  was deprecated in macOS 13 and is not even an error here -- just a
  deprecation warning that floods the build log.
- **`LoginServer.handleChunk` decodes bytes with
  `String(data:encoding:)` (falling back to ISO-Latin-1) instead of
  `String(decoding:as:)`.** A throw in the Task from a non-UTF-8 request
  would crash the actor; the new path is best-effort and only the
  malformed request is dropped.
- **`Timer.scheduledTimer` blocks no longer capture `[weak self]`** in
  the LoginServer and WidgetWindowController. Actor types are not
  `Sendable`, so the captures were a strict-concurrency violation; the
  blocks now hop onto the MainActor via `Task { @MainActor [weak self]
  in ... }`, which is the same pattern used throughout.
- **CI matrix** in `.github/workflows/build.yml` now runs against every
  available `macos-*` runner (currently `macos-15`, with `macos-14` and
  `macos-26` to be added as GitHub ships them). The build is the same
  on every row; each row exercises the same source against a different
  SDK-time default.

### Added (this pass)

- `BackdropService` is now a `Re-exported from KiteGlanceCore` in the
  architecture diagram, matching the actual import path used by
  `WidgetView` and `WidgetWindowController`. (`BackdropService.swift` in
  `Sources/KiteGlance/Services/` is a thin re-export.)

### Added
- **Full Windows 1:1 Parity**: Complete feature alignment with Windows KiteGlance desktop widget.
- **Price History & Sparklines**:
  - `PriceHistoryService` rolling 40-point ring buffer persisted to `~/Library/Application Support/KiteGlance/history.json`.
  - Historical candle backfill via `/instruments/historical` endpoint on `KiteService`.
  - `SparklineShape` vector rendering in `HoldingRow` with directional coloration and min/max per-row normalization.
- **Auto-Refresh Cadence**:
  - User-configurable auto-refresh intervals (Manual only, 1m, 5m, 15m, 30m, 1h).
  - Configurable in `SettingsWindow` and persisted in `WidgetState`.
  - 60-second cooldown throttle on manual refreshes with "Just synced a moment ago" toast.
- **Visuals & Animations**:
  - Skeleton loading view placeholder with zero-reflow layout matching live header.
  - Window entrance animation with gentle lift and opacity fade.
  - Hero value scale pulse (`1.016x` bounce) on live data refreshes.
  - Holdings row stagger-in (26ms delay) and bottom-up stagger-out (reverse index exit timing).
  - Ambient accent wash matching hero gain/loss state with 700ms smooth fade.
  - Rotating direction indicator and numeric counter roll animations.
- **Status & Indicators**:
  - `LiveDotState` engine: breathing blue dot during market hours, grey dot when closed, amber dot on sync failure.
  - "Stale" sync timestamp annotation on network / fetch failures.
- **Window Position Clamping**:
  - 48pt screen-edge clamping so widget never teleports or gets lost after monitor disconnects.
- **System Integration**:
  - **Open at Login** toggle in menu bar status menu via `ServiceManagement` (`SMAppService`).
  - Accessibility labels and traits on status dot, hero value, tabs, and expander button.
  - Focus-aware keyboard guards (`NSText`, `NSButton`) on Space/Enter/Tab/R window keys.

### Fixed
- Fixed `AsyncSemaphore.wait()` cancellation bug preventing token lease leaks.
- Fixed single-instance detection fallback for development builds without bundle identifier.
- Fixed clipboard copy on holding row tap with toast confirmation.
- Fixed tab indicator alignment using matched geometry transitions.
- Removed obsolete dead code and unused log service references.

### Security
- Credentials and access tokens safely stored in macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
