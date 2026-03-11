# Meridian

Native macOS app for running Windows Steam games through Wine + GPTK (Game Porting Toolkit).

## How It Works

1. **Sign in with Steam** via OpenID (`ASWebAuthenticationSession`), no Steam password stored by Meridian.
2. **Fetch library metadata** from Steam Web API (`IPlayerService/GetOwnedGames`).
3. **Launch games through Wine** — DirectX calls are translated to Metal via D3DMetal (Apple GPTK).
4. **Steam runs silently** in the background inside a Wine prefix. Session files are copied from macOS Steam for auto-login.
5. **Games render natively** through Metal — no VM, no virtual display, just native macOS windows.

## Architecture

```
MeridianApp (SwiftUI)
├── Steam/           — OpenID auth, Web API, library sync, session bridge
├── Engine/          — Wine+GPTK runtime management, prefix management, Steam lifecycle
├── Launch/          — Game launch orchestration
├── Models/          — Game, AppSettings, PlayerSummary, AppDetails
└── Views/           — Library, game detail, settings, auth, engine setup
```

### Translation Stack

```
Windows Game (.exe)
    → Wine (Win32 API translation)
        → GPTK / D3DMetal (DirectX → Metal)
            → Metal GPU (native rendering)
```

No VM. No guest OS. No virtio. Games run as macOS processes.

## Game Launch Flow

1. User clicks **Play** in the library
2. Meridian verifies Wine+GPTK runtime is installed
3. Creates or reuses Wine prefix (`~/Library/Application Support/com.meridian.app/bottles/steam/`)
4. Copies macOS Steam session files for auto-login (if Steam for Mac is installed)
5. Starts `steam.exe -silent` in Wine (background, no visible window)
6. Waits for Steam IPC readiness
7. Launches game via `steam://rungameid/<APPID>` protocol
8. Game window appears as a native macOS window
9. Game exits → returns to library

## Requirements

- macOS 15+ (macOS 26 recommended)
- Apple Silicon Mac
- Xcode 16+ / Swift 6
- Steam Web API key: [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey)

## First-Time Setup

1. Open `Meridian.xcodeproj` in Xcode.
2. Set your Team in Signing & Capabilities.
3. Build and run.
4. Sign in with Steam and provide your API key.
5. Click **Set Up Engine** when prompted to download the Wine+GPTK runtime (~2–3 GB).
6. Click **Play** on any game — Steam installs into the Wine prefix automatically.

## Engine Runtime

The Wine+GPTK runtime is downloaded from GitHub releases and stored at:

```
~/Library/Application Support/com.meridian.app/engine/
├── wine/bin/wine64        — Wine binary
└── lib/                   — D3DMetal, DXVK, system libraries
```

The GitHub repo slug is configurable in Settings (default: `aftrnd/meridian`).

## Wine Prefix

A single shared Wine prefix is used for Steam and all games:

```
~/Library/Application Support/com.meridian.app/bottles/steam/
├── drive_c/               — Virtual C:\ drive
│   └── Program Files (x86)/Steam/  — Steam installation
├── system.reg             — Windows registry
└── user.reg               — User registry
```

## Steam Session

Meridian copies session files from macOS Steam (`~/Library/Application Support/Steam/`) into the Wine prefix to enable auto-login:

- `config/loginusers.vdf` — logged-in user
- `config/config.vdf` — auth tokens
- `registry.vdf` — Steam settings
- `ssfn*` — machine auth tokens

If macOS Steam is not installed, the user signs into Steam once inside the Wine window. Steam remembers credentials for all subsequent launches.

## Known Limitations

- **Anti-cheat**: EasyAntiCheat and BattlEye block Wine/GPTK on macOS. Most competitive online games will not work.
- **Denuvo DRM**: Poor compatibility under Wine. Many Denuvo-protected titles will fail.
- **First Steam login**: Steam Guard may require one-time email/authenticator verification even with session copy.
- **Performance**: Translation overhead exists. Most games run well on M-series Macs, but heavy DX12/ray-tracing titles may struggle.
- **Not all games work**: Compatibility varies by game. This is inherent to Wine/GPTK translation.

## Settings

| Setting | Description |
|---------|-------------|
| Engine Repo Slug | GitHub repo for Wine+GPTK releases |
| Metal HUD | Show GPU performance overlay |
| Virtual Desktop | Force fixed-resolution Wine desktop |
| Steam Web API Key | Required for library sync |
