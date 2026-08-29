# KiteGlance for macOS

A native macOS desktop widget for your Zerodha portfolio, tracking the Windows [KiteGlance](https://github.com/sasly2048/KiteGlance) project.

This codebase aims for feature parity with the Windows build but is on a different release cadence — the Windows build carries several fixes (the KiteService tolerant-parse fix, the LoginServer cancellation-message fix, the OnStartup mutex guard, the audit pass, the re-audit pass, the third-party audit pass, the Windows `Key.Space` when-guard, and the intraday 5-minute sparklines from 1.5.0) that the macOS build picked up in the [Unreleased] section of `CHANGELOG.md`. The macOS build uses a Cocoa-native architecture (`NSWindow.Level` for desktop pinning, `NSHostingView` for SwiftUI, macOS Keychain for credential storage, `NWListener` for the loopback OAuth server) rather than a 1:1 port. The CHANGELOG lists what is and is not yet in the macOS build.

## Features

- **Live portfolio P&L** — Overall and per-holding, split into Stocks and Funds tabs
- **Accurate mutual-fund NAVs** — Overrides Kite's stale settlement NAVs with live NAVs from AMFI
- **Desktop pinning** — Stays on desktop below all windows, above wallpaper (like a true widget)
- **8 time-based backdrops** — Dawn, Sunrise, Morning, Noon, Dusk, Evening, Night, Midnight with smooth crossfades. Boundaries track the Indian sky (Asia/Kolkata), not the host timezone.
- **Native macOS materials** — Vibrancy, blur, rounded corners, system shadows
- **Spring animations** — Layout uses damped harmonic oscillator; numbers use quartic ease-out (no overshoot)
- **Skeleton loading** — Zero-layout-shift skeleton screens
- **Live indicator** — Pulsing dot during market hours (Mon–Fri 09:15–15:30 IST)
- **Secure credentials** — Encrypted in macOS Keychain; the Settings window deliberately does *not* echo the secret back when opened, and an empty Save means "keep the stored secret"
- **OAuth loopback** — Captures redirect on `http://127.0.0.1:5173/callback`
- **Auto-refresh** — Every 5 minutes during market hours
- **Intraday sparklines** — Subscribed Kite accounts get 5-minute candles down-sampled to fit each row's chart; the resulting series is frozen so the per-refresh `last_price` does not pile a single non-aligned point on the right edge
- **Keyboard shortcuts** — Space/Enter to expand, Esc to collapse, R to refresh, Tab to switch tabs, **Up/Down arrows to navigate holdings, Enter to copy the selected ticker to the clipboard**
- **Status bar menu** — Pin modes, backgrounds, settings, quit

## Requirements

- **macOS 15 Sequoia through macOS 26** (Tahoe, if/when released)
- Apple Silicon (primary) or Intel
- Zerodha account with Kite Connect API access ([developers.kite.trade](https://developers.kite.trade))

The Package.swift floor is `.macOS(.v15)`, but the same code base compiles
and runs on every macOS the CI matrix exercises (currently `macos-15`,
adding runners as GitHub ships them). Nothing in the codebase calls a
macOS 16/17/18/26-only API directly: the highest-versioned AppKit symbol
in use is `NSVisualEffectView.material = .hudWindow`, available since
macOS 10.10, and the system renders it as Liquid Glass on macOS 26
without any code change. The widget looks the same on a 2023 MacBook
as on a 2026 Mac Studio -- the OS draws it differently, but the
painted pixels are identical.

## Building from Source

### Prerequisites

- Xcode 16+ or Swift 6 toolchain
- macOS 15 SDK (deployment target 15, builds and tests on later SDKs)
- (Optional) Apple Developer account for signing/notarization

### Verifying the build works on every macOS

The CI workflow (`.github/workflows/build.yml`) runs `swift build` and
`swift test` on each `macos-*` runner GitHub currently hosts. To run the
same matrix locally against the SDK you have installed:

```bash
swift build -c debug
swift test
swift build -c release --arch arm64
```

If you have multiple Xcode versions installed, switch the active one
and re-run to exercise the matrix by hand:

```bash
sudo xcode-select -s /Applications/Xcode_16.0.app/Contents/Developer
swift build -c release
sudo xcode-select -s /Applications/Xcode_16.4.app/Contents/Developer
swift build -c release
```

The build is the same on Apple Silicon and Intel (the `arch: arm64` in
the release command flips to `x86_64` for the latter).

### Quick Development Build (no signing)

```bash
git clone https://github.com/yourusername/KiteGlance-macOS
cd KiteGlance-macOS

# One command: generates assets, builds debug, creates runnable .app
./scripts/quick-run.sh

# Then run:
open .build/debug/KiteGlance.app
```

### Release Build (signed, notarizable)

```bash
# 1. Generate assets & build release binary
swift run generate-assets
swift build -c release --arch arm64

# 2. Create signed .app bundle (requires Developer ID)
./scripts/build-app.sh --sign "Developer ID Application: Your Name (TEAMID)"

# 3. Full pipeline: sign + notarize + staple
./scripts/build-app.sh \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --notarize --keychain-profile "notary-profile"

# Output:
#   dist/KiteGlance.app          (signed, notarized, stapled)
#   dist/KiteGlance-1.0.0.dmg    (signed, notarized, stapled)
```

### Create .app Bundle Manually

```bash
# After building release binary:
mkdir -p KiteGlance.app/Contents/{MacOS,Resources}
cp .build/arm64-apple-macosx/release/KiteGlance KiteGlance.app/Contents/MacOS/
cp Sources/KiteGlance/Info.plist KiteGlance.app/Contents/
# Generate AppIcon.icns from Sources/KiteGlance/Assets/Icons/app-icon.png
# (use iconutil or the build-app.sh script)

# Ad-hoc sign for local testing:
codesign --force --deep --sign - KiteGlance.app

# Run:
open KiteGlance.app
```

## Installation

1. Download the latest `KiteGlance.app` from Releases
2. Drag to `/Applications`
3. Right-click → Open (first run only, due to Gatekeeper)
4. Click the menu bar icon → Settings → Enter your Kite Connect API key and secret
5. Sign in with Kite when prompted

## Configuration

### Kite Connect App Setup

1. Go to [developers.kite.trade](https://developers.kite.trade) and create an app
2. Set **Redirect URL** to exactly:
   ```
   http://127.0.0.1:5173/callback
   ```
   > **Keep port 5173 free during login.** KiteGlance briefly listens on this port to catch the OAuth redirect.

3. Note your **API key** and **API secret**
4. Enter them in KiteGlance Settings (menu bar → Settings)

> **macOS sandbox note.** The OAuth loopback listener binds to
> `127.0.0.1:5173`, which requires the
> `com.apple.security.network.server` entitlement. This is declared
> in `KiteGlance.entitlements` for both the signed and unsigned
> builds. The preflight lint (`scripts/preflight.py`) fails the
> build if the entitlement is removed; a fresh checkout should
> "just work" on every macOS the project supports.

### Environment Variables (Development)

```bash
export KITE_API_KEY="your_api_key"
export KITE_API_SECRET="your_api_secret"
export KITEGLANCE_DEBUG=1  # enables debug logging
```

## Usage

- **Menu bar icon** — Click for menu: Refresh, Pin Mode, Background, Settings, Quit
- **Widget header** — Drag to reposition; Click to expand/collapse
- **Space / Enter** — Expand/collapse holdings
- **Esc** — Collapse holdings
- **R** — Manual refresh (throttled to once/minute)
- **Tab** — Switch between Stocks/Funds tabs
- **Click holding row** — Copy symbol to clipboard
- **Hover holding row** — See exact quantity and average price in tooltip

### Pin Modes

| Mode | Behavior |
|------|----------|
| **Pin to Desktop** (default) | Bottom-most z-order, under all apps, above wallpaper. Stays on all Spaces. |
| **Always on Top** | Floats above all windows. |
| **Float Freely** | Normal window behavior. |

### Backgrounds

- **Time of Day** — Automatically transitions through 8 phases following system clock
- **Rotate** — Cycles through all backdrops every 3 hours
- **Graphite (Static)** — Fixed noon backdrop
- **Choose Image…** — Custom image (copied locally, scrim applied for readability)

## Architecture

```
Sources/KiteGlance/
├── App.swift                    # App entry, status bar, single instance
├── Interop/
│   ├── WidgetWindowController.swift  # Borderless window at desktop level
│   ├── VisualEffectMaterial.swift     # macOS 15-25 → .hudWindow, 26+ → .glass (Liquid Glass)
├── Services/
│   ├── KiteService.swift        # Kite Connect API + portfolio assembly
│   ├── AmfiNavService.swift     # Live MF NAVs from AMFI (cached daily)
│   ├── CredentialVault.swift    # macOS Keychain encryption
│   ├── BackdropService.swift    # Re-exported from KiteGlanceCore
│   ├── PnlMath.swift            # Re-exported from KiteGlanceCore
│   ├── LoginServer.swift        # Loopback OAuth on port 5173
│   └── Log.swift                # Rotating file logger
├── ViewModels/
│   └── PortfolioViewModel.swift # Observable state, computed properties
├── Views/
│   ├── WidgetView.swift         # Main widget UI (compact + expanded)
│   ├── HoldingRow.swift         # Individual holding row
│   └── SettingsWindow.swift     # Credentials entry
├── State/
│   └── WidgetState.swift        # Persisted position, tabs, pin mode, backdrop
└── Assets/
    ├── Backdrops/               # 8 mesh-gradient PNGs (dawn → midnight)
    └── Icons/                   # App icon

Sources/KiteGlanceCore/         # Plain net8.0-style library; no AppKit
├── Accounts.swift               # AccountRef + AccountResolver
├── BackdropService.swift        # Time-based backdrop selection
├── FundNameFormatter.swift     # "HDFC MID-CAP OPPORTUNITIES" → "HDFC Mid-cap"
├── KeychainNaming.swift         # account-id → keychain-suffix
├── MoneyRounding.swift          # AwayFromZero helper (shared with Windows)
├── NavParser.swift             # AMFI NAVAll.txt → [ISIN: Decimal]
├── PnlMath.swift                # P&L arithmetic (tested)
├── Portfolio.swift              # PortfolioData + PortfolioAssembler
├── PriceSeries.swift            # 40-point ring buffer + downsample
├── PriceHistory.swift           # Frozen set for intraday-seeded series
├── RefreshInterval.swift       # 1...60 clamp, 0 means off
└── ThemeMode.swift              # ThemeMode + ResolvedTheme
```

### Data Flow

1. **Boot** → Load state → Initialize services → Check auth → Fetch portfolio
2. **Refresh** → Acquire semaphore → Fetch Kite equity/MF → Override MF NAVs from AMFI → Update ViewModel
3. **Auto-refresh** → Timer fires every N minutes during market hours (configurable in Settings; default 5 min)

### Threading

- UI: MainActor (SwiftUI)
- API: Async/await with actor isolation
- File I/O: Async where possible

## Performance Targets

- **Launch**: < 500ms to visible widget
- **Idle RAM**: < 30 MB
- **Idle CPU**: < 0.5%
- **Refresh**: < 2s end-to-end
- **Animations**: 120 Hz smooth (ProMotion)

## Security

- Credentials encrypted in macOS Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
- No backend, no telemetry, no analytics
- OAuth redirect captured locally on loopback (no admin rights)
- API tokens never logged
- Sandboxed with minimal entitlements (network client + server for OAuth)

## Disclaimer

**Not affiliated with Zerodha.** Independent, open-source client for the public Kite Connect API. Market data may be delayed or inaccurate; do not rely on it for trading decisions. Always verify against official Kite and Coin apps.

## License

MIT License — see [LICENSE](LICENSE)