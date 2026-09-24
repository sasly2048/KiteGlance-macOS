# Testing KiteGlance

KiteGlance has two test surfaces: the `KiteGlanceTests` XCTest suite
that ships with the repo, and the manual end-to-end checklist that a
release candidate is run through before tagging.

## Running the unit tests

```sh
swift test
```

That is the whole thing. `Package.swift` declares
`KiteGlanceTests` as the only test target, and the only dependency
the test target has is `KiteGlanceCore` — `XCTest` cannot import an
executable target, so the AppKit-touched `KiteGlance` target is not
in scope. This is intentional: every behaviour that can be lifted
into `KiteGlanceCore` (math, name formatting, AMFI parsing, theme
resolution) has been, and what remains in `KiteGlance` is the
`AppKit`-only glue.

If a test was useful enough to write, the behaviour it covers is
useful enough to be testable, so any new test that needs
`NSWindowController` or `NSImage` is a smell that the behaviour
should move to `KiteGlanceCore` first.

## What is covered

- **Money & P&L math** — `PnlMathTests`, `MoneyRoundingTests`. The
  half-away-from-zero rule, day-PnL exclusion of T1, Kite-vs-computed
  reconciliation, the "unpriced holding is held at cost" rule.
- **Portfolio assembly** — `PortfolioAssemblerTests`. T1-exclusion,
  zero-close-price, blank-name fallbacks, AMFI NAV override, empty
  portfolio. Mirrors the Windows `KiteService.FetchPortfolioAsync`
  rules.
- **Account resolution** — `AccountResolverTests`. The
  "labelled-without-credentials" bug from the 1.5.0 audit: a listed
  account that has no Keychain item must not be treated as signed in.
- **AMFI NAV parsing** — `NavParserTests`. The split-on-all-semicolons
  rule and the NAV-is-second-from-last position.
- **Backdrop service** — `BackdropServiceTests`. Hour boundaries,
  rotation stability, all-eight reachable.
- **Name formatting** — `FundNameFormatterTests`. FoF, brand
  acronyms, blank/whitespace.
- **Keychain naming** — `KeychainNamingTests`. Nil/empty/collision
  paths.
- **Price series** — `PriceSeriesTests` + `PriceHistoryServiceTests`.
  Capacity, frozen-guard, weekend-of-identicals, downsample
  midpoint-pick.
- **Theme parity** — `PaletteTests`. `Palette.dark` and
  `Palette.light` define the same fields, the chrome and overlay
  scrim are not `.clear`, the backdrop tint opacity actually differs
  between themes, and the positive/negative accents are distinct.
- **Secret merge rule** — `SecretMergeTests`. The Settings
  "empty-secret-keeps-stored" rule extracted as a pure function.
- **Structured-log renderer** — `LogRenderTests`. The `{Name}`-hole
  renderer used by the optional JSONL sink.
- **Refresh interval & theme** — `RefreshIntervalTests`,
  `ThemeModeTests`. The 1...60 clamp, `0` meaning "off", and the
  `System` / `Dark` / `Light` resolution.

## What is not covered (and why)

- **`KiteService` HTTP paths.** Mock-URLProtocol tests would require
  a redirect-the-actor's-`URLSession.shared` shim that does not exist
  yet. The Mac `KiteService` is an actor; the Windows `KiteService`
  is also untested through HTTP for the same reason.
- **`CredentialVault` Keychain reads/writes.** Keychain tests would
  need a real login keychain. The Vault's *logic* (per-account
  scoping, merge rule) is in Core and tested; the *Keychain API* is
  not.
- **`LoginServer` and `AmfiNavService` over the network.** Both
  services are tested in their pure paths (request parsing, cache
  fallback) but not with mock listeners.
- **SwiftUI views.** `WidgetView`, `SettingsWindow`, the tab-bar
  underline animation — none of these are under test. The view layer
  is the smallest part of the codebase; testing it would buy
  snapshot-test infrastructure that is not yet worth maintaining.

## Manual end-to-end checklist

This is the list a release candidate is run through on a fresh
macOS install. The most expensive of these is the network round-trip
through Kite's OAuth flow, which is why they are not automated.

1. **First launch** shows the connect overlay, not an empty widget.
2. **Settings → save with empty secret** keeps the stored secret
   (the `SecretMerge.resolve` rule).
3. **Settings → save with both fields filled** rewrites both.
4. **Kite OAuth** opens the browser, captures the request token from
   the loopback listener, and lands on the portfolio.
5. **T1 holding** is held at cost until the next market close; the
   day-PnL figure does not include it.
6. **Mutual fund** uses the live AMFI NAV when reachable, and the
   stale-fallback warning appears in the sync label when not.
7. **Auto-refresh** fires on the configured interval while the
   market is open, and is silent outside market hours.
8. **Manual refresh** (status menu → Refresh, or `r` while the widget
   is focused) overrides the throttle.
9. **Pin mode** changes take effect immediately: desktop, always-on-
   top, and float-freely all reposition the window as expected.
10. **Theme** switch re-paints the widget and the status menu in
    step.
11. **Light/dark system appearance** with `Theme = .system` flips
    the widget automatically.
12. **Custom backdrop** is read from disk; > 8 MB is rejected with
    a toast.
13. **Open at Login** registers a launch agent; the toggle in
    Settings matches the one in the status menu.
14. **Hide widget** (`Show Widget` menu) makes the window
    order-out; reopening makes it order-in.
15. **Quit** writes the position and active tab; relaunch restores
    both.
16. **Force-quit** does not leave a stale launch agent registered
    (the `SingleInstance` check at launch self-heals).

## Adding a new test

- Pure logic (math, parsing, name formatting, merge rules) goes in
  `KiteGlanceCore` and the test goes in `Tests/KiteGlanceTests/`.
- Anything that touches `NSWindow`, `NSImage`, `URLSession`, or
  Keychain is not unit-testable today. Lift the pure parts out, then
  test those.
- A new field on `Palette` requires an entry in both `Palette.dark`
  and `Palette.light`. The `PaletteTests.testDarkAndLightDefineTheSameKeys`
  test will fail if you forget one.
