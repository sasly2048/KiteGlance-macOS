# Backdrops

Generated, not committed. Run:

```bash
swift run generate-assets
```

This writes `backdrop-*.png` (eight, one per phase of the day) and `grain.png`
here, plus `../Icons/app-icon.png`.

The app does not require them: `Assets.backdrop(_:)` returns nil when a PNG is
absent and `WidgetView` falls back to `BackdropImage.fallbackGradient`. Running
the generator replaces those flat gradients with the real mesh-gradient art.

This directory previously held `.txt` placeholders with names like
`backdrop-dawn.txt`. They were never loadable as images — nothing reads `.txt`
here — so they have been removed.
