name: Bug report
about: Something in the widget is broken or behaves wrong
title: "[bug] "
labels: ["bug"]
assignees: []

---

## What happened

A short, factual description of the bug. Avoid speculation; describe
the observation.

## Steps to reproduce

1.
2.
3.

## Expected

What you expected to happen.

## Actual

What actually happened. Paste any error text verbatim -- KiteGlance
writes the user-facing message to the log, but the developer-facing
details (status codes, exception types) are not shown to the user.

## Environment

- KiteGlance version: (look in **About KiteGlance** in the status menu)
- macOS version: (`sw_vers`)
- Mac model: (Apple silicon vs Intel)
- Network: (Wi-Fi vs wired, VPN on/off)

## Logs

If the issue is reproducible, the log file is the first place a
maintainer will look. It is at
`~/Library/Application Support/KiteGlance/logs/kiteglance.log` (and,
if you enabled it, `kiteglance.jsonl`). Set `KITEGLANCE_DEBUG=1` in
the environment before launching to get debug-level entries.

```sh
# Copy the last 100 lines of each log to the clipboard
tail -n 100 ~/Library/Application\ Support/KiteGlance/logs/kiteglance.log | pbcopy
```

## Screenshots

If the widget renders incorrectly, a screenshot is worth a thousand
words. The widget is `Cmd-Shift-4` screen-shot-able; crop to the
relevant region.

## Notes

Anything else that might be relevant: a market-hours condition, a
specific holding, an account that uses the multi-account feature.
