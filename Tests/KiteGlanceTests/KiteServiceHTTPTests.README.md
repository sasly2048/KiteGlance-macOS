# KiteService HTTP tests — removed pending a testable seam

`KiteServiceHTTPTests.swift` was removed because it could not compile: it
`import`ed `KiteGlanceCore` but instantiated `KiteService`, which lives in the
`KiteGlance` **executable** target. XCTest cannot import an executable target
(see the comment in `Package.swift`), so the whole test suite failed to build.

To restore real HTTP coverage, move `KiteService` (+ its DTOs and
`CredentialVault` dependency) into `KiteGlanceCore` — it imports only
`Foundation`, `CryptoKit`, `KiteGlanceCore`, and `os.log` (no AppKit/SwiftUI),
so the move is clean — then re-add the `MockURLProtocol`-based tests importing
`KiteGlanceCore`.
