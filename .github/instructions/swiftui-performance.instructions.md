---
description: "SwiftUI performance rules for Meridian's UI layer. Apply when editing views, image loading, observable stores, or anything touching the main actor."
applyTo: "Meridian/Views/**,Meridian/Steam/SteamLibraryStore.swift,Meridian/Steam/SteamWindow.swift,Meridian/Models/**"
---

# SwiftUI Performance Rules (Meridian)

Prime directive: **performance fixes must never change what the user sees.** Same layout, same colors, same perceived animations — just faster.

## Main-actor hygiene

- Never call `NSImage(data:)` or `NSImage(contentsOf:)` on the main actor. Decode via `Task.detached(priority: .userInitiated)` (or a nonisolated async helper), then hand the finished image back to the UI.
- No synchronous disk I/O (`FileManager` scans, ACF reads, cache file reads) inside `@MainActor` code paths, view `body`, or view `.task` blocks. Move it to a background task and publish only the result.
- Avoid redundant syscalls: don't `fileExists()` before an open that already fails gracefully.

## Observation & invalidation

- Batch `@Observable` mutations: compute changes off to the side, apply in one pass, and skip the write entirely when nothing changed (no-op writes still invalidate views).
- Keep polling loops rare and cheap: pause them when their result can't change (e.g. install polling while a game is running), and prefer event sources (file watchers, process exit handlers) over timers when possible.
- Views should observe the narrowest state possible; extract subviews so a mutation only invalidates the cards/rows that actually changed.

## Grid & hover effects

- Hover/tilt effects on cards must be debounced or threshold-gated (skip updates < 2pt movement) and use a single `.animation(_:value:)` per card, not stacked animation modifiers.
- `ForEach` must use stable identity (`Game.id`); never index-based IDs in the library grid.
- Don't recompute derived values (tilt angles, gradients) in `body` when they can be stored or cached.

## Images

- All artwork goes through `ImageCache` (two-tier: NSCache + disk). Always pass `rawData` to `store()` so the disk tier never re-encodes.
- Downsample large art (hero/banner) to display size before caching in memory when feasible — but never change perceived visual quality.

## Timers

- Justify every `Timer`/sleep-loop interval in a comment. Current known intervals: install-state poll (SteamLibraryStore), window-suppression poll (SteamWindow, guard tested in WindowClassificationTests), home carousel (HomeView).
- Before changing an interval or timer API, check `MeridianTests/` — several contract tests assert on the literal source text.

## Process & tracking

- Every performance change must be logged in `docs/PERFORMANCE-IMPROVEMENTS.md` (status, measurement, risk).
- Measure before/after when possible (Instruments: SwiftUI template, Time Profiler, or `os_signpost`).
