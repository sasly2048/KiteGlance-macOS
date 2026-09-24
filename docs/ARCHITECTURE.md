# KiteGlance macOS — Architecture Documentation

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      KiteGlance Widget                          │
├─────────────────────────────────────────────────────────────────┤
│  UI Layer (SwiftUI)                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ WidgetView   │  │ SettingsView │  │ Status Menu  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
├─────────────────────────────────────────────────────────────────┤
│  ViewModels (@MainActor)                                        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ PortfolioViewModel                                       │   │
│  └──────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  Services Layer (Actors)                                        │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐   │
│  │ KiteSvc    │ │ AMFI Svc   │ │Keychain    │ │ Backdrop   │   │
│  └────────────┘ └────────────┘ └────────────┘ └────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  Motion System                                                  │
│  ┌────────────────┐  ┌────────────────┐                        │
│  │ SpringEase    │  │ NumeralTween  │                        │
│  └────────────────┘  └────────────────┘                        │
├─────────────────────────────────────────────────────────────────┤
│  State & Interop                                                │
│  ┌────────────┐  ┌────────────┐                                │
│  │ WidgetState│  │ WindowCtrl  │                                │
│  └────────────┘  └────────────┘                                │
└─────────────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ┌──────────┐    ┌──────────┐    ┌──────────┐
    │ Kite API │    │ AMFI NAV │    │ Keychain │
    │ (HTTPS)  │    │ (HTTPS)  │    │ (Secure) │
    └──────────┘    └──────────┘    └──────────┘
```

## Component Details

### App Entry (`App.swift`)
- `NSApplication` with `.accessory` policy (no Dock icon)
- Single-instance guard via `NSRunningApplication`
- Status bar item (`NSStatusItem`) for menu access
- `WidgetWindowController` manages the desktop widget window

### Widget Window (`WidgetWindowController.swift`)
- Borderless `NSWindow` with `.nonactivatingPanel` style
- Level: `.desktop` (default), `.floating`, or `.normal`
- Collection behavior: `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`
- Transparent background, system shadow, rounded corners via `NSVisualEffectView`
- Drag handling on header area
- Frame animations via `NSAnimationContext`

### Services

#### `KiteService` (Actor)
- OAuth flow: Loopback server on port 5173 → Exchange request token → Store access token
- Portfolio fetch: Parallel equity + MF holdings → AMFI NAV override → `PortfolioData`
- Semaphore-gated refresh (prevents concurrent calls)
- Token expiry detection (403/401 with `TokenException`)
- Debug dump via `KITEGLANCE_DEBUG=1`

#### `AmfiNavService` (Actor)
- Fetches `NAVAll.txt` once per IST day
- Parses semicolon-delimited format, indexes by ISIN (both growth & reinvest)
- Disk cache in `~/Library/Application Support/KiteGlance/amfi-nav.txt`
- Memory cache with IST-day validity
- Graceful fallback: disk cache → memory cache → Kite NAVs

#### `CredentialVault` (Actor)
- macOS Keychain (`kSecClassGenericPassword`)
- Service: `com.kiteglance.credentials`, Account: `kite-connect`
- Accessible: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Stores: `apiKey`, `apiSecret`, `accessToken`, `savedAt`
- Environment variable override for development

#### `BackdropService` (Struct)
- Pure functions: `pick(mode, date) -> BackdropImage`
- Time-of-day: 8 phases based on hour (IST)
- Rotate: `(dayOfYear * 8 + hour/3) % 8` — deterministic per day
- Static: Always `.day` (Graphite)
- Custom: User image path stored in state

#### `PnlMath` (Struct)
- Pure arithmetic, no dependencies
- `invested = qty * avgPrice`
- `pnl`: Kite's apiPnl if non-zero, else `(last - avg) * qty`
- `current`: Consistent with pnl by construction
- `pnlPct = pnl / invested * 100`

#### `LoginServer` (Actor)
- `NWListener` on `127.0.0.1:5173`
- Parses OAuth callback for `request_token`
- Returns success HTML page
- 5-minute timeout, proper cleanup

#### `Log` (Actor)
- Unified logging via `os.log` + rotating file
- Levels: Debug, Info, Warn, Error
- File: `~/Library/Application Support/KiteGlance/logs/kiteglance.log`
- Rotation at 1 MB, keeps 1 backup
- `KITEGLANCE_DEBUG=1` enables Debug level

### ViewModels

#### `PortfolioViewModel` (@MainActor)
- `@Published` portfolio, loading, error, sync time, stale NAV flag
- Computed: stocks/funds split, hero values, invested/current/overall
- Market hours detection (IST, Mon–Fri 09:15–15:30)
- Sync label formatting: "just now" / "4m ago" / "at 3:30 pm"
- Overlay state for auth/setup flows

#### `HoldingViewModel` (@MainActor, Identifiable)
- Wraps `Holding` with formatting
- `symbol` (pretty name), `pnlColor`, `tooltip`
- All P&L via `PnlMath` — single source of truth

### Motion System (`SpringEase.swift`)

#### Spring Physics
```
x'' + 2ζω₀x' + ω₀²x = 0
ω₀ = √(stiffness/mass)
ζ = damping / (2√(stiffness·mass))
```
- **Layout** (stiffness: 170, damping: 20) — slight overshoot, feels physical
- **Gentle** (130, 22) — softer landing, no visible bounce
- **Snap** (320, 24) — snappy, immediate

#### Quartic Ease-Out (Numbers)
```
ease(t) = 1 - (1 - t)⁴
```
- Fast departure, patient arrival
- **Never overshoots** — money must not render phantom values

#### `NumeralTween` (Global)
- Single `CADisplayLink` drives all number animations
- `ConditionalWeakTable`-style via `ObjectIdentifier` keys
- Retarget mid-flight from current visual value (no jumps)
- 680ms default duration for hero, 640ms for secondary

### State Persistence (`WidgetState.swift`)

```swift
struct WidgetState: Codable {
    var position: CGPoint = .zero
    var isExpanded: Bool = false
    var activeTab: String = "stocks"
    var pinMode: PinMode = .desktop
    var backdropMode: BackdropMode = .timeOfDay
    var customBackdropPath: String?
    var lastSync: Date?
}
```
- JSON at `~/Library/Application Support/KiteGlance/widget-state.json`
- Debounced save (600ms) on position change
- Immediate save on explicit user actions

### Views

#### `WidgetView` (Main)
- ZStack: Backdrop layers → Grain → Sheen → Accent wash → Content
- Two backdrop images for crossfade transitions
- Compact (256pt) ↔ Expanded (up to 592pt) with spring animation
- Skeleton loading (zero reflow)
- Toast notifications (auto-dismiss)

#### `HoldingRow`
- PnL color bar (2pt) on left
- Symbol, invested → current, P&L + return%
- Hover: lift 2px + background fade (spring)
- Click: copy symbol + toast
- Tooltip: raw symbol, exact qty, avg price, current price

#### `SettingsWindow`
- Borderless floating panel
- API key/secret fields with monospace font
- Save → Keychain → Reload credentials → Refetch
- DPAPI/Keychain explanation text

## Data Flow

### Bootstrap
```
App launch
  → WidgetWindowController.init()
    → restore position from WidgetState
    → apply pin mode (window level)
    → start timers (ticker, session check, auto-refresh)
  → bootstrap()
    → if no credentials: show Connect overlay
    → else if not authenticated: show Login overlay
    → else fetchPortfolio()
      → PortfolioViewModel updated
      → skeleton → content crossfade
```

### Refresh Cycle
```
Timer fires (5 min during market hours)
  → KiteService.getPortfolio()
    → _refreshGate.wait()
    → GET /portfolio/holdings + /mf/holdings
    → AmfiNavService.getAllNavs() (if funds exist)
    → Merge: override MF last_price with AMFI NAV
    → Build PortfolioData via PnlMath
    → PortfolioViewModel.portfolio = data
    → lastSync = now, usingStaleNavs flag
  → _refreshGate.signal()
```

### Backdrop Update
```
Ticker fires (20s)
  → BackdropService.pick(mode, now)
  → if changed: crossfade over 1.2s (quadratic ease-in-out)
  → scrim fade for custom images
```

## Platform Integration

### Desktop Pinning (`.desktop` level)
- `NSWindow.level = .desktop` (kCGDesktopWindowLevel)
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`
- Stays below all apps, above wallpaper
- Visible on all Spaces
- Does not appear in Mission Control / App Switcher

### Window Materials
- `NSVisualEffectView` with `.windowBackground` material
- `.popover` blending mode for vibrancy
- Rounded corners via `mask` in SwiftUI
- System shadow automatic at `.desktop` level

### Multi-Monitor
- Position restored relative to screen's visible frame
- `isOnScreen` validation on launch (handles display removal)
- Widget stays on Space where positioned

### Dark/Light Mode
- All colors use semantic system colors or explicit dark-mode values
- Backdrops are dark by design (work in both modes)
- `NSVisualEffectView` adapts automatically

## Security Model

| Asset | Protection |
|-------|------------|
| API Key/Secret | Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly) |
| Access Token | Keychain (same), cleared on 403 TokenException |
| AMFI Cache | Plaintext (public data) in App Support |
| State JSON | Plaintext (no secrets) in App Support |
| Logs | No credentials, no PII, no NAV/holding values |
| Network | HTTPS only, pinned to api.kite.trade & amfiindia.com |

## Performance Characteristics

| Metric | Target | Implementation |
|--------|--------|----------------|
| Cold launch | < 500ms | Minimal deps, lazy view loading |
| Idle RAM | < 30 MB | No image caching beyond backdrops |
| Idle CPU | < 0.5% | Timers only fire when needed |
| Refresh latency | < 2s | Parallel equity+MF, semaphore |
| Animation FPS | 120 Hz | Core Animation, CADisplayLink |
| Memory growth | Zero | No leaks, actors clean up |

## Extensibility Points

1. **New data source** → Add Service actor, integrate in `KiteService.fetchPortfolio`
2. **New UI panel** → Add to `WidgetView` ZStack, control via ViewModel
3. **New pin mode** → Extend `PinMode`, handle in `applyPinMode()`
4. **New animation** → Add `SpringEase` preset or custom `Animation`
5. **New export format** → Add to `Money` or new formatter

## Testing Strategy

- **Unit**: `PnlMath`, `BackdropService`, `Money`, `AccountResolver`,
  `NavParser`, `PriceSeries`, `SecretMerge`, `Log.render` (all in
  `KiteGlanceCore`).
- **Integration**: `KiteService` with `URLProtocol` mock (not yet
  shipped — would require a `URLSession` shim in the actor).
- **Actor isolation**: Verify no main-thread blocking.
- **Memory**: `leaks` tool on debug build.
- **UI**: Manual verification (SwiftUI testing limited). The end-to-end
  checklist lives in `docs/TESTING.md`.
- **Theme parity**: `PaletteTests.testDarkAndLightDefineTheSameKeys`
  catches any field defined in one palette but not the other.

## Future Considerations

- WidgetKit extension for Notification Center (read-only).
- Sparkline charts per holding (Canvas + spring animation). The
  per-holding sparkline already exists; this is about graduating it
  from `Path` to a `Canvas` for finer control over axis labels.
- Multi-account support (tab bar in settings). Per-account Keychain
  scoping already works; what is missing is a UI to manage them.
- Keyboard shortcut customization.
- AppleScript/Shortcuts integration.