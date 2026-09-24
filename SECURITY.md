# Security Policy

## Reporting a vulnerability

If you find a security issue in Kite Glance, please **do not open a public
issue**. Instead:

1. Go to the repository's **Security** tab on GitHub.
2. Click **Report a vulnerability** to open a private advisory.

You should get an initial response within a few days. Please include:

- A description of the issue and its potential impact
- Steps to reproduce (a minimal repro helps a lot)
- The version / commit you tested against

## Supported versions

Only the latest released version is supported with security fixes. Please
update before reporting.

## What this app does with your data

Understanding the data flow is the fastest way to reason about risk here:

- **Credentials** (Kite Connect API key and secret) are stored in the
  **macOS Keychain** as `kSecClassGenericPassword` items, scoped to this
  app's bundle id. They are not readable by another app and not
  decryptable by copying the file to a different machine. The Keychain
  encryption key is tied to the user's login password on FileVault-enabled
  Macs.
- **Access tokens** (which Kite Connect rotates daily) are stored the
  same way, with a separate Keychain item so the secret can be replaced
  without touching the token and vice versa.
- **Per-account scoping**: every account has its own Keychain items
  (named `kiteglance.<accountId>.<field>`). Switching accounts does not
  carry one account's credentials to another, even in memory: the
  `CredentialVault` actor is rebuilt on `useAccount(...)` with the old
  values cleared first.
- **Network access** is limited to `api.kite.trade` (portfolio data) and
  the Kite login flow in your default browser. The app makes no other
  outbound calls, and there is no analytics or telemetry.
- **The OAuth redirect** is captured by a loopback `NWListener` bound to
  `127.0.0.1:5173`. It only accepts connections from `localhost` and
  shuts down immediately after capturing the request token. The
  `com.apple.security.network.server` entitlement restricts the listener
  further to loopback-only.
- **The API dump** (`~/Library/Application Support/KiteGlance/api-dump.json`)
  contains your user id, email and full holdings in plaintext. It is
  written only when `KITEGLANCE_DEBUG=1` and is automatically purged on
  any non-debug launch, so it never outlives the debugging session it
  was created for.
- Nothing is ever sent to a third-party server. There is no backend for
  this project — it talks directly to Kite Connect's API from your
  machine.

## Reporting credential exposure

If you believe your Kite API key or access token has been exposed:

1. Regenerate your API secret at
   [developers.kite.trade](https://developers.kite.trade).
2. Revoke the affected access token from your
   [Kite account settings](https://kite.zerodha.com).
3. Clear the local vault: open Keychain Access, search for
   `kiteglance.`, and delete every item. Then re-enter fresh credentials
   in Settings.

## Scope

This policy covers the Kite Glance application code in this repository.
It does not cover Zerodha's Kite Connect API or infrastructure — for
issues there, contact Zerodha directly.
