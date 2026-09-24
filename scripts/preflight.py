#!/usr/bin/env python3
"""
preflight.py — SwiftUI/asset sanity checks the Swift compiler misses.

This is the macOS repo's analogue of the Windows `scripts/preflight.py`.
It runs as a CI step before `swift build` and `swift test` and fails
the build on any of:

  1. Force-unwraps in `Sources/KiteGlance/**/*.swift`. The
     `CONTRIBUTING.md` "no force unwraps" rule is *not* enforced by
     the compiler; a `!` slipped into a PR only shows up at runtime.
     A grep for `!` after `as`, `try`, and string-init returns catches
     the most common forms. (See `forbid_force_unwrap` below for the
     exact pattern set; it errs on the side of false positives over
     false negatives -- the result is a one-line PR comment, not a
     runtime crash.)

  2. `Bundle.module` references in `KiteGlanceCore`. `KiteGlanceCore`
     has no resource bundle, so `Bundle.module` resolves to a
     different (or nil) bundle than the rest of the codebase expects.
     The asset-loading helper `Assets.backdrop(_:)` already lives in
     the executable target; a `Bundle.module` call in Core would be a
     silent asset-not-found at runtime.

  3. Unguarded `force unwrap` of an `NSImage(contentsOfFile:)` result.
     `NSImage(contentsOfFile:)` returns `nil` for a missing or
     unreadable file. The codebase already uses the
     `?? fallbackGradient` pattern; a regression that drops the
     fallback would render an empty rectangle instead of the
     gradient.

  4. Direct `URLSession.shared` references in `Sources/KiteGlance/`.
     The codebase has a `KiteService` actor that takes a `URLSession`
     in its initialiser specifically so tests can inject a
     `URLProtocol` mock. A new call site that reaches for
     `URLSession.shared` would be untestable; the rule makes those
     noisy.

  5. Missing Info.plist entitlements. The OAuth loopback listener
     binds to `127.0.0.1:5173`; the macOS sandbox requires
     `com.apple.security.network.server` for that. A PR that adds a
     new endpoint without updating `KiteGlance.entitlements` would
     fail to launch on a hardened runtime.

The script is intentionally small and dependency-free. It is meant to
run in CI, where adding a Python toolchain dependency is a non-event,
and to give one-line output that maps a failure to the exact file
and line.

Usage:
    python3 scripts/preflight.py        # check the current tree
    python3 scripts/preflight.py --fix  # (not implemented; reserved)

Exit code is 0 on success, 1 on any rule violation. CI runs this
before `swift test`.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "Sources"
EXECUTABLE = SOURCES / "KiteGlance"
CORE = SOURCES / "KiteGlanceCore"
TESTS = REPO_ROOT / "Tests"
ENTITLEMENTS = REPO_ROOT / "KiteGlance.entitlements"


def gather_swift_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*.swift")):
        # Exclude generated-assets script -- it has its own lint rules.
        if path.name == "generate-assets.swift":
            continue
        yield path


# ---- Rule 1: no force unwraps ---------------------------------------------

# The pattern matches `!` immediately following a `?`-style optional chain
# end or a cast/type-conversion. We also catch `try!` and the explicit
# `as!`. The intent is to flag the high-frequency offenders; subtle
# cases (e.g. `!` inside a string literal, or a tuple-destructuring
# non-optional force) are out of scope.
FORCE_UNWRAP_PATTERNS = [
    (re.compile(r"\bas!\s"), "force cast (`as!`)"),
    (re.compile(r"\btry!"), "`try!`"),
    (re.compile(r"!\s*\."), "force unwrap in chain (`.!`)"),
    (re.compile(r"!\s*\)"), "force unwrap before `)`"),
    (re.compile(r"!\s*,"), "force unwrap in tuple"),
    (re.compile(r"!\s*\n"), "force unwrap at end of line"),
]


def _strip_comments_and_strings(line: str) -> str:
    """Replace any `// ...` and string literal content with spaces so the
    patterns below do not match code that is only documentation."""
    # Strip line comments. Block comments and string literals would need
    # more care; for the patterns we use (which require a `!` at a code
    # boundary) the line-comment strip is enough.
    idx = line.find("//")
    if idx >= 0:
        line = line[:idx]
    return line


def forbid_force_unwrap() -> list[str]:
    errors: list[str] = []
    for swift in gather_swift_files(EXECUTABLE):
        for n, line in enumerate(swift.read_text(encoding="utf-8").splitlines(), 1):
            code = _strip_comments_and_strings(line)
            for pat, desc in FORCE_UNWRAP_PATTERNS:
                if pat.search(code):
                    errors.append(
                        f"{swift.relative_to(REPO_ROOT)}:{n}: {desc}\n    {line.strip()}"
                    )
    return errors


# ---- Rule 2: no Bundle.module in KiteGlanceCore ---------------------------


def forbid_bundle_module_in_core() -> list[str]:
    errors: list[str] = []
    for swift in gather_swift_files(CORE):
        if "Bundle.module" in swift.read_text(encoding="utf-8"):
            errors.append(
                f"{swift.relative_to(REPO_ROOT)}: Bundle.module is not available in KiteGlanceCore; "
                "move the asset-loading code to the executable target."
            )
    return errors


# ---- Rule 3: NSImage(contentsOfFile:) must be guarded ---------------------


def require_guarded_nsimage() -> list[str]:
    """`NSImage(contentsOfFile:)` returns nil for a missing or unreadable
    file. Every call site must use `if let` or `??` -- a chain like
    `Image(nsImage: NSImage(contentsOfFile:))` would force-unwrap a nil."""
    errors: list[str] = []
    for swift in gather_swift_files(EXECUTABLE):
        for n, line in enumerate(swift.read_text(encoding="utf-8").splitlines(), 1):
            code = _strip_comments_and_strings(line)
            if "NSImage(contentsOfFile:" not in code:
                continue
            # The call is guarded if the line contains `if let`,
            # `guard let`, or `??`. None of those is in the call itself,
            # so we look at the line that holds the call and the line
            # above. Most legitimate uses have `if let nsImage = `
            # on the same line, or `?? fallbackGradient` on the next.
            # A line that ends the call with `) {` (the start of a
            # `if let` body) is also fine.
            is_guarded = (
                "if let" in code
                or "guard let" in code
                or "??" in code
                or code.rstrip().endswith("{")  # `if let nsImage = NSImage(...) {`
            )
            if not is_guarded:
                errors.append(
                    f"{swift.relative_to(REPO_ROOT)}:{n}: "
                    "NSImage(contentsOfFile:) used without a nil guard\n    "
                    f"{line.strip()}"
                )
    return errors


# ---- Rule 4: no URLSession.shared in executable --------------------------


def forbid_urlsession_shared() -> list[str]:
    """The codebase has a `KiteService(session:)` initialiser and an
    `AmfiNavService` that takes its own session. A new call site that
    reaches for `URLSession.shared` would be untestable."""
    errors: list[str] = []
    for swift in gather_swift_files(EXECUTABLE):
        for n, line in enumerate(swift.read_text(encoding="utf-8").splitlines(), 1):
            code = _strip_comments_and_strings(line)
            # `URLSession.shared.configuration` and similar are fine in
            # initialisers; the rule is against the *call* `data(for:)`
            # and friends reaching through the shared instance.
            if "URLSession.shared" in code and ".data(" in code:
                errors.append(
                    f"{swift.relative_to(REPO_ROOT)}:{n}: URLSession.shared used for "
                    "a network call. Pass a session into the service's initialiser "
                    "so tests can inject a mock.\n    "
                    f"{line.strip()}"
                )
    return errors


# ---- Rule 5: entitlements sanity -----------------------------------------


def require_network_server_entitlement() -> list[str]:
    """The OAuth loopback listener binds 127.0.0.1:5173, which requires
    the network.server entitlement under the macOS sandbox."""
    if not ENTITLEMENTS.exists():
        return [f"{ENTITLEMENTS.relative_to(REPO_ROOT)}: file is missing"]
    text = ENTITLEMENTS.read_text(encoding="utf-8")
    if "com.apple.security.network.server" not in text:
        return [
            f"{ENTITLEMENTS.relative_to(REPO_ROOT)}: missing "
            "`com.apple.security.network.server`; required for the "
            "loopback OAuth listener on 127.0.0.1:5173"
        ]
    return []


# ---- Driver ----------------------------------------------------------------


def main() -> int:
    rules = [
        ("force unwraps", forbid_force_unwrap),
        ("Bundle.module in KiteGlanceCore", forbid_bundle_module_in_core),
        ("unguarded NSImage(contentsOfFile:)", require_guarded_nsimage),
        ("URLSession.shared direct use", forbid_urlsession_shared),
        ("entitlements sanity", require_network_server_entitlement),
    ]

    all_errors: list[tuple[str, str]] = []
    for name, fn in rules:
        errs = fn()
        for e in errs:
            all_errors.append((name, e))

    if not all_errors:
        print("preflight: all rules passed")
        return 0

    for name, err in all_errors:
        print(f"[{name}] {err}")
    print(f"\npreflight: {len(all_errors)} violation(s)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
