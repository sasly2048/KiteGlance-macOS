# Multi-account support

A Kite user can have more than one Kite Connect app (e.g. a personal
account and a trading-bot account). KiteGlance supports switching
between them, with each account's credentials kept in its own Keychain
slot. This document is the data-flow view; the implementation lives in
`KiteGlanceCore/Accounts.swift` and `Sources/KiteGlance/Services/CredentialVault.swift`.

## The three rules

1. **A listed account is a label, not a credential.** A user who has
   signed in once and then deleted the Keychain entry for that account
   (or never had it -- e.g. by editing the JSON by hand) should not
   see the account as "available" in the status menu. The
   `AccountResolver` probe (`(String) -> Bool`) is the only source of
   truth for "is this account usable", and it must return `false` if
   the Keychain has no entry for the id.

2. **Switching accounts clears in-memory credentials, then reloads.**
   The `KiteService.useAccount(_:)` actor method binds a *new*
   `CredentialVault` (one per account) and zeroes the in-memory
   `apiKey` / `accessToken` *before* reloading. This is so a user who
   switches to an account that has no stored credentials sees the
   connect overlay, not the previous account's portfolio under the
   new label.

3. **Per-account Keychain items use a stable suffix.** The Keychain
   helper `KeychainNaming` appends the Kite user id to every key:
   `kiteglance.credentials@AB1234`, `kiteglance.access-token@AB1234`,
   and so on. A user with two accounts (say `AB1234` and `CD5678`)
   has six Keychain items; switching accounts is just a
   `useAccount` call that selects a different suffix. There is no
   `pending` folder, no staging write, and no atomic-rename dance --
   the suffix *is* the per-account namespace.

## The data flow on account switch

```
status menu → "Account" → user picks id CD5678
  │
  ▼
AppDelegate.switchAccount(_:)         (target=_selectAccount on AppDelegate)
  │
  ▼
WidgetWindowController.switchToAccount(CD5678)
  │
  ▼
state.activeAccountId = CD5678        (persisted immediately)
  │
  ▼
Task: resolvedAccountId()             (re-resolve against Keychain)
  │   ├─ for each account: CredentialVault(id).hasStoredCredentials()
  │   └─ AccountResolver.resolvedAccountId(accounts, activeAccountId, probe)
  │       → if active is in the list AND probe(active) == true → return active
  │       → else first account where probe(id) == true
  │       → else nil  (only when no account has credentials)
  │
  ├─ if nil:
  │     viewModel.portfolio = nil
  │     promptToConnect()             (overlay, not sign-in)
  │     rebuildStatusMenu()
  │     return
  │
  ▼
kiteService.useAccount(resolved)      (rebinds the actor's vault)
  │
  ▼
viewModel.portfolio = nil             (so the old portfolio does not flash)
  │
  ▼
bootstrap()                           (full re-resolution path)
  │   ├─ viewModel.activeTab = state.activeTab
  │   ├─ if no usable account → promptToConnect, return
  │   ├─ if not authenticated → promptToSignIn, return
  │   └─ fetchPortfolio()            (the same path the app uses at launch)
  │
  ▼
rebuildStatusMenu()                   (move the tick to the new id)
```

The flow is the same path the app takes at launch, minus the
"create widget window" step. This is what makes the menu's tick mark
honest: the user sees the *resolved* active id, never the
*remembered* active id, so a stale `activeAccountId` in the JSON
(which is normal during a half-finished onboarding) cannot leak into
the displayed state.

## Why the probe is a closure, not a stored property

`WidgetState` is `Codable` and crosses actor boundaries, so a
`CredentialVault` reference cannot be stored on it. A closure is
neither encodable nor `Sendable`, so the probe has to be passed in at
the call site. `AccountResolver.resolvedAccountId(accounts:, activeAccountId:, probe:)`
takes the probe as a parameter, and the controller does the work of
constructing one:

```swift
private func resolvedAccountId() async -> String? {
    var usable: Set<String> = []
    for account in state.accounts
    where await CredentialVault(accountId: account.id).hasStoredCredentials() {
        usable.insert(account.id)
    }
    return state.resolvedAccountId { usable.contains($0) }
}
```

The `usable` set is built once per resolution rather than probed
twice (once in the loop, once in the resolver) -- O(N) actor
creations per call, which is fine for the N ≤ 5 we expect.

## What this protects against

The classic regression in this area is the "labelled without
credentials" account: a user has signed in, the menu shows their
account, then the Keychain entry is removed (manual cleanup, macOS
profile wipe, etc.). Without the probe check, the menu still shows
the account, the app builds a login URL with `api_key=` empty, and
Kite returns an error page -- while the account is still listed in
the menu, looking signed in. The probe check collapses this to
"no usable account, show the connect overlay" which is the honest
state.

The `AccountResolverTests` in `Tests/KiteGlanceTests/` cover this
case as the regression suite: the "labelled account with no
credentials resolves to nil" test is the bug-that-was-fixed, pinned
so it cannot return.
