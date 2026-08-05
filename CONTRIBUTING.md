# Contributing to KiteGlance macOS

## Development Setup

1. **Prerequisites**
   - macOS 15+ with Xcode 16+
   - Swift 6 toolchain
   - Kite Connect API credentials for testing

2. **Clone and Build**
   ```bash
   git clone https://github.com/yourusername/KiteGlance-macOS
   cd KiteGlance-macOS
   swift run generate-assets
   swift build -c debug
   ```

3. **Run**
   ```bash
   .build/debug/KiteGlance
   ```

## Code Style

- **Swift 6** with strict concurrency checking
- **SwiftUI** for all UI (no AppKit view subclasses except window controller)
- **Actors** for all services (thread-safe by default)
- **@MainActor** for ViewModels and UI state
- **No force unwraps** — use `guard let` or `if let`
- **Async/await** throughout — no completion handlers

## Architecture Guidelines

### Services (Actors)
- Single responsibility: Kite API, AMFI NAV, Keychain, Backdrop, Logging
- Pure functions where possible (e.g., `PnlMath`, `BackdropService`)
- Errors thrown as typed `LocalizedError`
- Network calls use `URLSession` with proper timeouts

### ViewModels (@MainActor)
- ObservableObject with `@Published` properties
- Computed properties for derived state (no stored derived state)
- Actions are `func` that mutate state
- No business logic — delegate to services

### Views
- Single file per view
- `@ObservedObject` for ViewModels
- `@State` for local UI state only
- Animations use `.spring()` or custom `SpringEase`
- No logic in `body` — extract to ViewModel

### Motion System
- **Layout**: Spring physics (damped harmonic oscillator) — overshoot is intentional
- **Numbers**: Quartic ease-out — never overshoot (money must be honest)
- **Global ticker**: Single `CADisplayLink` drives all number animations

## Testing

```bash
# Run all tests
swift test

# Run with coverage
swift test --enable-code-coverage
xcrun llvm-cov export -format=lcov .build/debug/KiteGlanceTests.xctest/Contents/MacOS/KiteGlanceTests -instr-profile .build/debug/codecov/default.profdata > coverage.lcov
```

### Test Structure
- Unit tests for `PnlMath`, `BackdropService`, `Money` formatting
- Integration tests for `KiteService` (mocked HTTP)
- No UI tests (SwiftUI testing not mature)

## Pull Request Checklist

- [ ] `swift build -c release` succeeds
- [ ] `swift test` passes
- [ ] No new warnings
- [ ] Animations feel smooth at 120 Hz
- [ ] Memory usage stable during auto-refresh
- [ ] Dark/Light mode both work
- [ ] Multiple monitor placement works
- [ ] OAuth flow works with real Kite credentials

## Adding Features

1. **New API endpoint** → Add to `KiteService` with proper DTOs
2. **New UI element** → Add to `WidgetView` or new view file, expose via ViewModel
3. **New setting** → Add to `WidgetState`, `SettingsWindow`, and status menu
4. **New animation** → Use existing `SpringEase` presets or add new one

## Release Process

```bash
# Update version in Package.swift and Info.plist
git tag v1.0.0
git push origin v1.0.0
# GitHub Actions builds and creates release
```

## Debugging Tips

- Set `KITEGLANCE_DEBUG=1` for verbose logging
- Logs at `~/Library/Application Support/KiteGlance/logs/kiteglance.log`
- Use `Console.app` to filter by `subsystem:com.kiteglance`
- View hierarchy debugger: Xcode → Debug View Hierarchy

## Code of Conduct

- Be respectful and inclusive
- No secrets in code or logs
- Security issues: email security@kiteglance.example.com (see SECURITY.md)