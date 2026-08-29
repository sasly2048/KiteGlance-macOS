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

### Known Gaps

The items below are pre-existing and were not introduced by this commit.
Tracked here so they are not lost; fixing them is a separate task.

- The skeleton overlay referenced by `showSkeleton` is not rendered in
  `body`. First paint shows the live layout, which is fine in practice,
  but the original intent (per the 1.0.0 changelog) was a zero-reflow
  placeholder. The `@State` is now in place; the body needs an `if
  showSkeleton` branch.
- `WidgetWindow.mouseDown(with:)` is overridden but AppKit does not call
  it for borderless windows -- the content view handles mouseDown. The
  header drag is therefore not wired to the `NSWindow` override; the
  view itself relies on the SwiftUI environment. The comment at the
  override says `WidgetWindow.mouseDown already drags the header strip
  using the real event`, which is the intent but does not match what
  AppKit actually does.
- `Open at Login` (`SMAppService`) is claimed in the 1.0.0 changelog
  but is not wired in the source. The settings menu has no
  corresponding toggle.
- `LoginServer.receive` decodes the request body with
  `String(decoding:as:)` which throws on non-UTF-8 input. A non-UTF-8
  request (some HTTP clients send Latin-1) would crash the Task. The
  safer pattern is `String(data: buffered, encoding: .utf8) ?? ""` or
  a `try?`.
- `Settings.save` uses `Task { @MainActor in ... }` (after this commit)
  but the original `defer { isSaving = false }` is inside the Task body.
  A second click before the first Task runs sets `isSaving = true`
  again; the first Task's `defer` then flips it back to `false` even
  though the second Task is still in flight. The race is small but
  exists. Move the `defer` outside the Task.

---

## [1.0.0] - 2026-08-20

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
