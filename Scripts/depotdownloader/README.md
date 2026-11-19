# Meridian DepotDownloader fork

Meridian installs owned Steam games **headlessly** — no `steam.exe`, no Steam UI,
no windows or sounds — by driving a patched fork of
[SteamRE/DepotDownloader](https://github.com/SteamRE/DepotDownloader).

## Why a fork

Meridian's strategy is **"Steam does ONLY the DRM runtime; everything else runs
without it."** DepotDownloader is a battle-tested, SteamKit2-based CDN/manifest/
resume client. The fork adapts it to consume Meridian's existing OAuth
`refresh_token` so installs are single-sign-on and fully non-interactive.

Crucially, the same client-platform `refresh_token` that `steam.exe` rejects with
`Invalid Password` under Wine is **accepted** by SteamKit2's logon path, so
DepotDownloader installs work even when the Wine `steam.exe` silent auto-login
does not.

## What the patch adds

`meridian-task1.patch` (against upstream `b2b7e975`, DepotDownloader v3.4.0,
GPL-2.0) modifies `Program.cs`, `Steam3Session.cs`, `ContentDownloader.cs`,
`DownloadConfig.cs` and adds `MeridianJson.cs`:

- **`-refreshtoken <jwt>`** — inject into `SteamUser.LogOnDetails.AccessToken`.
  Interactive credential / QR / Steam-Guard auth is **removed** (it had regressed
  into a Guard retry loop; Meridian never needs it). Requires BOTH `-username`
  and `-refreshtoken` (or neither, for anonymous).
- **`-json`** — newline-delimited JSON progress on stdout (see schema below).
- **`-appinfo <id,id,…>`** — dump library art HASHES (logo / capsule / hero) from
  PICS appinfo as NDJSON, then exit. Does NOT require `-app`. Works
  **anonymously** (the appinfo `common` section is public), so no token is needed.
  This is the ONLY public source of the library **logo** hash: Steam's
  `IStoreBrowseService/GetItems` API returns capsule/hero/header/icon but NEVER a
  logo, and the legacy `/steam/apps/{id}/logo.png` 404s for newer titles. The
  logo lives only in `common.library_assets_full.library_logo`. Meridian's
  library reads it for game artwork.
- **SIGTERM / SIGINT** → deterministic exit `130` (resume-safe; the partial
  download's `.DepotDownloader/depot.config` lets the next run resume).

`meridian-task1.patch` is the complete patch: it applies cleanly to upstream
`b2b7e975`, and `build-depotdownloader.sh` builds the fork from it.

## Invocation (proven contract)

```
DepotDownloader -app <appID> -os windows -osarch 64 \
    -username <name> -refreshtoken <jwt> \
    -json -dir <installDir>
```

`-os windows -osarch 64` is **required**: DepotDownloader defaults to the HOST OS
(macOS) otherwise.

### Exit codes

| Code | Meaning |
|---|---|
| 0   | success |
| 1   | usage / access error |
| 3   | `REFRESH_TOKEN_INVALID` (fail-fast, no Guard loop) |
| 130 | SIGTERM/SIGINT (resume-safe) |

### NDJSON schema (stdout)

Human-readable `%` progress lines are also printed; the caller parses **only**
lines beginning with `{`.

```jsonc
{"type":"phase","phase":"connecting|loggedon|downloading|error","detail":"..."}
{"type":"progress","bytesDone":N,"bytesTotal":N,"pct":NN.NN}
{"type":"done","bytesDownloaded":N}
{"type":"error","message":"..."}
{"type":"appinfo","appid":N,"logo":"<40-hex>","capsule":"<40-hex>","hero":"<40-hex>","logoPinned":"<BottomLeft|CenterCenter|…>","logoWidthPct":D,"logoHeightPct":D}
```

`logoPinned` / `logoWidthPct` / `logoHeightPct` come from
`library_logo.logo_position` and reproduce Steam's own library logo placement
(anchor corner + box size as a % of the hero). Used by the game-detail hero.

Meridian's installer reads the progress lines, and its library the `appinfo`
lines.

### `-appinfo` invocation

```
DepotDownloader -appinfo 3588490,4244510
```

No `-username` / `-refreshtoken` required (anonymous). One `appinfo` line per id;
an empty string for any asset the app doesn't publish.

## Building

```bash
bash Scripts/build-depotdownloader.sh            # → into the live engine
bash Scripts/build-depotdownloader.sh /path/out  # explicit output path
```

Requires `dotnet` SDK 9+ (`brew install dotnet`). The script clones upstream at
the pinned commit, applies `meridian-task1.patch`, and publishes a self-contained
single-file `osx-arm64` binary, stripping `com.apple.quarantine` (macOS 26
blocks network access for quarantined binaries).

`Scripts/engine/package-engine.sh` stages the binary into the engine tarball at
`engine/tools/depotdownloader/DepotDownloader`; the engine-wide quarantine strip
on download covers it. Meridian runs it from there.

## License

The fork is GPL-2.0 (inherited from upstream). `LICENSE` is the upstream license
verbatim. The fork binary ships as a **separate executable** invoked as a
subprocess — it is not linked into Meridian.
