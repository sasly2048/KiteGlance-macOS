# Changelog

All notable changes to **KiteGlance macOS** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
