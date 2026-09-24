name: Pull request

about: Submit a change to KiteGlance

---

## What this PR does

A one-paragraph summary. The commit history is the implementation;
this is the *why*.

## Linked issues

Closes #... (if any). If the PR fixes a bug, name the issue. If it
implements a feature, link the feature request.

## Test plan

- [ ] `python3 scripts/preflight.py` passes
- [ ] `swift test` passes
- [ ] Manual smoke test (describe what you did)

For UI changes, attach before/after screenshots or a screen
recording. For behaviour changes, paste the relevant log lines.

## Test coverage

If you added a new function, did you add a test? If you couldn't
(for the reasons in `docs/TESTING.md`), say so in a comment on the
PR so a maintainer can suggest the right place to lift the logic.

## Checklist

- [ ] Branched off `master`
- [ ] No force unwraps (the preflight linter will catch this)
- [ ] CHANGELOG.md updated under the `[Unreleased]` section
- [ ] No new external SwiftPM dependencies (the project is
      intentionally dependency-free)

## Notes

Anything else a reviewer should know.
