# Meridian — Implementation Reference

## Overview

Meridian is a native macOS 26 app that runs Windows Steam games on Apple Silicon
via a lightweight Linux VM (Ubuntu + Proton), making the entire Linux/Proton layer
invisible to the user. The user signs in with Steam once and plays their games as
if they were native apps.

---

## What Is Built

### 1. Steam Authentication (`Meridian/Steam/`)

#### `SteamAuthService.swift`
The central auth object, `@Observable @MainActor`.

**Sign-in flow:**
1. A temporary localhost HTTP server (`SteamLocalAuthServer`) is bound on a random
   port via BSD sockets.
2. Steam's OpenID endpoint only accepts `http://` or `https://` as `return_to` —
   custom URI schemes (`meridian://`) are rejected server-side. The loopback server
   acts as the RFC 8252 §7.3 broker: Steam redirects to `http://127.0.0.1:{port}/openid/callback`,
   we extract the SteamID, then issue a `302 → meridian://auth/callback?steamid=<id>`.
3. `ASWebAuthenticationSession` is configured with `callbackURLScheme: "meridian"` and
   intercepts the `meridian://` redirect.
4. `handleCallback` extracts the SteamID, stores it in Keychain, fetches the player
   profile via the Steam Web API, and sets `isAuthenticated = true`.
5. A post-sign-in sheet prompts for the Steam Web API key (dismissible, remembered via
   `UserDefaults`).

**Credentials stored in Keychain:**
- `meridian.steam.steamid` — the user's 64-bit Steam ID
- `meridian.steam.apikey` — Steam Web API key for library/profile fetches
- `meridian.steam.vm.username` / `.vm.password` — fallback credentials for VM auto-login

**Session restore:** On launch, if a SteamID exists in Keychain, the user is
automatically authenticated and the profile is refreshed in the background.

#### `SteamLocalAuthServer.swift`
Minimal BSD-socket HTTP server. Handles exactly one request then shuts down.
Uses raw `socket`/`bind`/`listen`/`accept`/`recv`/`send` instead of
`Network.framework` `NWListener` because NWListener produces `EINVAL` in sandboxed
apps even with the correct entitlements.

#### `SteamAPIService.swift`
Direct calls to `api.steampowered.com` using the user's own API key. No backend
proxy. Endpoints used:
- `ISteamUser/GetPlayerSummaries/v0002` — display name, avatar
- `IPlayerService/GetOwnedGames/v0001` — full owned library
- `IPlayerService/GetRecentlyPlayedGames/v0005` — recently played

#### `SteamLibraryStore.swift`
`@Observable @MainActor` store that holds the game list, handles filtering
(All / Recent / Installed), sorting (name, playtime, recent), and search.

#### `SteamSessionBridge.swift`
Prepares Steam session files in a staging directory before VM boot. Two strategies:

1. **Session file copy** — if macOS Steam is installed, copies
   `config/loginusers.vdf`, `config/config.vdf`, and `registry.vdf` into the staging
   directory. The guest init script transplants these files into the in-VM Steam data
   directory before Steam starts → auto-login with no credentials entered.

2. **Credential injection fallback** — writes `credentials.env`
   (`STEAM_USER=…\nSTEAM_PASS=…`) to the staging directory with `0600` permissions.
   The guest init script runs `steam +login $USER $PASS`, then deletes the file.

The staging directory is mounted read-only into the VM via virtio-fs so the guest
cannot modify host Steam data.

---

### 2. VM Layer (`Meridian/VM/`)

#### `VMManager.swift`
`@Observable @MainActor`. All `VZVirtualMachine` calls are dispatched to a dedicated
serial `DispatchQueue` (`com.meridian.vm`) as required by Virtualization.framework.
State updates are marshalled back to `@MainActor`.

States: `notProvisioned → stopped → starting → ready → stopping → stopped`
(also `checkingForUpdate`, `downloading`, `assembling`, `error`).

#### `VMConfiguration.swift`
Builds a `VZVirtualMachineConfiguration`. Hardware layout:

| Device | Type | Purpose |
|--------|------|---------|
| CPU | Configurable (Settings) | |
| RAM | Configurable (Settings) | |
| Boot | `VZLinuxBootLoader` | kernel `vmlinuz` + `initrd` from image |
| Disk 0 | `VZVirtioBlockDevice` read-only | Meridian base image |
| Disk 1 | `VZVirtioBlockDevice` read-write | Per-user expansion disk (game installs) |
| Network | `VZVirtioNetworkDevice` NAT | Outbound internet for Steam/updates |
| GPU | `VZVirtioGraphicsDevice` 1920×1080 | Game display |
| Input | `VZUSBKeyboard` + `VZUSBScreenCoordinatePointingDevice` | |
| Entropy | `VZVirtioEntropyDevice` | RNG for SSL etc. |
| Serial | `VZVirtioConsoleSerial` hvc0 | ProtonBridge RPC channel |
| FS share 0 | virtio-fs `meridian-games` | Host↔guest game library path |
| FS share 1 | virtio-fs `meridian-steam-session` (read-only) | Steam session/credential staging |

Kernel command line: `quiet loglevel=0 console=hvc0 meridian=1`

#### `VMImageProvider.swift`
`@Observable @MainActor`. Fetches the latest Meridian base image from GitHub
Releases via `GET /repos/{owner}/{repo}/releases/latest`. The repo slug is
configurable in Settings so users can self-host or use a fork without recompiling.

Image packaging: assets named `meridian-base.img.part1` / `meridian-base.img.part2`
(split due to GitHub's 2 GiB asset limit). Assembly concatenates the parts and
stores the result in Application Support.

#### `ProtonBridge.swift`
Swift `actor` that communicates with the `meridian-bridge` daemon running inside the
VM over a Unix socket (`proton-bridge.sock`) backed by the virtio-serial port.

Protocol is line-delimited JSON:
```
Host → Guest: { "cmd": "launch", "appid": 1091500, "steamid": "76561..." }
Guest → Host: { "event": "started", "pid": 12345 }
Guest → Host: { "event": "exited",  "code": 0 }
Guest → Host: { "event": "log",     "line": "proton: ..." }
```

#### `GameLauncher.swift`
`@Observable @MainActor`. Orchestrates the full launch pipeline:
1. `SteamSessionBridge.prepare()` — stage session files
2. `VMManager.start()` — boot VM if not running
3. `ProtonBridge.connect()` with retry loop (socket may not exist the instant the VM boots)
4. Register log/exit handlers
5. `ProtonBridge.launchGame(appID:steamID:)` — send JSON launch command

---

### 3. UI (`Meridian/Views/`)

| View | Purpose |
|------|---------|
| `AuthView` | Sign-in screen with "Sign in with Steam" button |
| `APIKeySetupSheet` | Post-auth sheet to enter Steam Web API key (in `ContentView`) |
| `ContentView` | Root: switches between `AuthView` and main `NavigationSplitView` |
| `LibraryView` | Game grid with search + sort toolbar |
| `GameGridView` | Individual game tile (artwork, name, playtime) |
| `GameDetailView` | Right panel: game info, Play/Install button, VM view embed |
| `VMStatusBarView` | Bottom-overlay pill showing live VM state + Stop button |
| `VMProvisionView` | Download progress sheet shown during base image fetch |
| `SettingsView` | API key, VM credentials, image repo, CPU/RAM/disk, storage management |
| `SidebarView` | Filter list (All Games / Recently Played / Installed) |

---

### 4. App Infrastructure

#### Entitlements (`Meridian.entitlements`)
```xml
com.apple.security.network.server  = true   <!-- loopback auth server -->
com.apple.security.network.client  = true   <!-- Steam API + GitHub releases -->
com.apple.security.app-sandbox     = true
```

#### `AppSettings.swift`
`UserDefaults`-backed settings: image repo slug, VM CPU count, RAM, disk size,
`apiKeyPromptDismissed` flag.

---

### 5. Critical Swift 6 / macOS 26 Fixes

These were non-obvious runtime crashes that required deep investigation.

#### Fix 1 — `presentationAnchor` called off main queue
`ASWebAuthenticationPresentationContextProviding` is an Objective-C protocol.
macOS 26 added `dispatch_assert_queue(main_queue)` to `NSApp.keyWindow`.
When `ASWebAuthenticationSession` called `presentationAnchor(for:)` from the Safari
XPC queue, it crashed.

**Fix:** Capture `NSApp.keyWindow ?? NSWindow()` on the main actor *before*
`session.start()`. Store in `nonisolated(unsafe) var capturedPresentationWindow`.
The `nonisolated` delegate method returns the pre-captured value — no AppKit calls
from the XPC thread.

#### Fix 2 — Completion handler closure inferred as `@MainActor`
In Swift 6.2, `withCheckedThrowingContinuation(isolation: #isolation)` embeds the
calling actor's executor into the `CheckedContinuation` value. Any closure that
captures a `@MainActor`-derived `cont` — even with an explicit `[cont]` capture list
— is inferred by the compiler as `@MainActor`-isolated. The runtime inserts
`_swift_task_checkIsolatedSwift` at the closure entry. When `ASWebAuthenticationSession`
fired its completion handler on the Safari XPC queue (`com.apple.SafariLaunchAgent`),
that assertion failed.

**Fix:** Move `ASWebAuthenticationSession` creation into `makeWebAuthSession(url:cont:)`,
a `nonisolated` free function. Closures created there have no actor context — Swift 6
cannot inject the `@MainActor` check regardless of what `cont` carries internally.

#### Fix 3 — Sheet presented on a disappearing view
`APIKeySetupSheet` was originally attached to `AuthView`. Since `AuthView` is only
visible while `!isAuthenticated`, and the sheet's `isPresented` condition depends on
`isAuthenticated == true`, SwiftUI's layout engine tried to simultaneously remove
`AuthView` and present a sheet on it — causing a precondition failure.

**Fix:** Moved the sheet to `ContentView`'s `mainContent` branch, which is only
active when authenticated.

---

## What Comes Next — VM & Proton Integration

The Steam auth, library, credential staging, and VM lifecycle plumbing are all in
place. The remaining work is entirely on the **guest side** (the Meridian base image)
and the **host↔guest protocol**. Here is the full roadmap in priority order.

---

### Phase 1 — Meridian Base Image (Prerequisite for Everything Else)

The VM can boot once the base image is provisioned, but the image itself needs the
following components. These are built into the image at release time, not installed
at runtime.

#### 1.1 Guest OS baseline
- Ubuntu 24.04 LTS (ARM64, minimal server install)
- Kernel: stock Ubuntu kernel is fine; `vmlinuz` + `initrd` extracted and published
  alongside the disk image as separate GitHub Release assets
- `meridian=1` kernel param already passed — guest init can detect Meridian boot

#### 1.2 Steam for Linux (ARM64 via Box86/FEX-EMU)
Steam's Linux client is x86_64. On ARM64 there are two viable paths:
- **FEX-EMU** (recommended): open-source x86_64 emulator with better Proton
  compatibility than Box86 on Apple Silicon-class hardware
- **Box64**: simpler setup, slightly lower compatibility

The image must include FEX-EMU or Box64 pre-installed and Steam pre-bootstrapped
(so first launch doesn't require an x86_64 installer download).

#### 1.3 Proton
- Install a specific Proton-GE release into the image (e.g. `GE-Proton9-x`)
- Mount path: `/home/meridian/.steam/root/compatibilitytools.d/Proton-GE`
- `VMConfiguration` already passes the games share at `meridian-games` tag;
  the guest init must `mkdir -p /mnt/games` and `mount -t virtiofs meridian-games /mnt/games`

#### 1.4 virtio-fs mounts in guest init
The guest needs an init script (or systemd unit) that runs before Steam:
```bash
mkdir -p /mnt/steam-session /mnt/games
mount -t virtiofs meridian-steam-session /mnt/steam-session
mount -t virtiofs meridian-games /mnt/games
```

#### 1.5 Session/credential apply script
Runs after the virtio-fs mounts:
```bash
STEAM_DATA=/home/meridian/.steam/steam

# Strategy 1: session file copy
if [ -f /mnt/steam-session/config/loginusers.vdf ]; then
    mkdir -p $STEAM_DATA/config
    cp /mnt/steam-session/config/loginusers.vdf $STEAM_DATA/config/
    cp /mnt/steam-session/config/config.vdf     $STEAM_DATA/config/
    cp /mnt/steam-session/registry.vdf          $STEAM_DATA/
fi

# Strategy 2: credential injection
if [ -f /mnt/steam-session/credentials.env ]; then
    source /mnt/steam-session/credentials.env
    STEAM_LOGIN_ARGS="+login $STEAM_USER $STEAM_PASS"
    # credentials.env is read-only (host-side 0600), but signal the bridge
fi
```

#### 1.6 `meridian-bridge` daemon
A small process (Go or C) that:
- Opens `/dev/hvc0` (the virtio-serial port)
- Listens for line-delimited JSON commands from the host
- On `{ "cmd": "launch", "appid": X, "steamid": Y }`:
  - Launches Steam with `steam -applaunch <appid> -proton` (or equivalent)
  - Reports PID, stdout lines, and exit code back over hvc0
- The `ProtonBridge.swift` host actor already implements the counterpart

#### 1.7 ProtonBridge socket wiring
`VMConfiguration.makeSerialPort()` currently attaches `hvc0` to `/dev/null`.
This needs to be replaced with a `VZSocketDeviceConfiguration` or a
`VZFileHandleSerialPortAttachment` backed by a Unix socket pair so
`ProtonBridge.swift` can connect:

```swift
// Replace the /dev/null attachment:
let (hostSocket, guestSocket) = try makeSocketPair()
serial.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: FileHandle(fileDescriptor: guestSocket),
    fileHandleForWriting: FileHandle(fileDescriptor: guestSocket)
)
// Save hostSocket path so ProtonBridge can connect to it
```

---

### Phase 2 — Game Display

#### 2.1 `VZVirtualMachineView` integration
`VMManager.vmView` already returns a configured `VZVirtualMachineView`.
`GameDetailView` needs to embed it when a game is running:

```swift
// In GameDetailView, when vmManager.state.isRunning:
VMViewRepresentable(vmManager: vmManager)
```

Where `VMViewRepresentable` wraps `VZVirtualMachineView` in an `NSViewRepresentable`.

#### 2.2 Dynamic resolution
The guest GPU is set to 1920×1080. For proper HiDPI / window-resize support:
- Use `VZMacGraphicsDeviceConfiguration` or pass display dimensions via
  kernel command line when building the config
- The host window resize should send a `{ "cmd": "resize", "w": W, "h": H }`
  command over the bridge; the guest adjusts with `xrandr`

#### 2.3 Full-screen mode
- `NSWindow.toggleFullScreen` works naturally once `VZVirtualMachineView` is embedded
- `capturesSystemKeys = true` (already set) ensures the game gets keyboard shortcuts

---

### Phase 3 — Game Installation

When a user clicks Install on a game that isn't on the expansion disk:

1. Host sends `{ "cmd": "install", "appid": X }` over ProtonBridge
2. Guest runs `steam +login ... +app_update X validate +quit`
3. Bridge streams progress lines back: `{ "event": "log", "line": "... 45.3%" }`
4. `GameLauncher.logs` already accumulates these lines — `GameDetailView` can render them

The expansion disk (`expansion.img`) is already provisioned as a writable virtio-blk
device. Its default size is set in Settings (`vmDiskGiB`). The guest should symlink
Steam's `steamapps/` directory onto the expansion disk so installs land there rather
than on the read-only base image.

---

### Phase 4 — Image Versioning & Updates

`VMImageProvider` already polls GitHub Releases and compares `tagName` against the
cached tag. When a new image is available:

1. `VMImageProvider.checkForUpdate()` returns `true`
2. `VMStatusBarView` (or a menu item) offers "Update Available"
3. `VMImageProvider.downloadLatestImage(onProgress:)` downloads and assembles the new image
4. The old base image is replaced; the expansion disk is preserved (user's game installs survive)

**To-do in image publishing pipeline:**
- Split the assembled image: `split -b 1900m meridian-base.img meridian-base.img.part`
- Upload `meridian-base.img.part1`, `meridian-base.img.part2`, `vmlinuz`, `initrd`
  as GitHub Release assets under a semver tag
- Update `AppSettings.imageRepoSlug` default to match the production repo

---

### Phase 5 — Polish & Production Hardiness

| Item | Detail |
|------|--------|
| VM snapshot / suspend | `VZVirtualMachine` doesn't support snapshots; a fast save-state can be approximated by keeping the VM running in the background and pausing Proton |
| Game artwork | Steam CDN URL pattern: `https://cdn.akamai.steamstatic.com/steam/apps/{appid}/header.jpg` — load and cache in `GameGridView` |
| Install detection | Probe the expansion disk's `steamapps/appmanifest_{appid}.acf` via virtio-fs to show correct Install vs Play button state |
| Error recovery | If the VM crashes (`virtualMachine(_:didStopWithError:)`) mid-game, auto-restart with a user notification |
| Resource limits | `AppSettings.vmCPUCount` and `vmMemoryGiB` are wired to `VMConfiguration`; expose a performance-tier picker (Good / Better / Best) in Settings that translates to sensible CPU/RAM presets |
| Sandboxing hardening | The expansion disk, games share, and session staging dir all live in Application Support — this is correct for App Store submission. Review entitlements before submitting. |
| Notarisation | Virtualization.framework requires `com.apple.vm.device-access` entitlement for production; confirm provisioning profile includes it |

---

## File Map

```
Meridian/
├── App/
│   ├── AppDelegate.swift          Window configuration
│   └── MeridianApp.swift          @main, environment injection, menus
├── Launch/
│   └── GameLauncher.swift         Full launch pipeline orchestrator
├── Models/
│   ├── AppDetails.swift           App version constants
│   ├── AppSettings.swift          UserDefaults-backed settings
│   ├── Game.swift                 Steam game model
│   ├── PlayerSummary.swift        Steam player profile model
│   └── VMState.swift              VM lifecycle state enum
├── Steam/
│   ├── SteamAPIService.swift      Direct Steam Web API calls
│   ├── SteamAuthService.swift     OpenID sign-in, Keychain, session restore
│   ├── SteamLibraryStore.swift    Game list with filter/sort/search
│   ├── SteamLocalAuthServer.swift BSD-socket loopback OpenID broker
│   └── SteamSessionBridge.swift   Host→guest Steam session file staging
├── VM/
│   ├── ProtonBridge.swift         Host↔guest JSON-over-serial RPC
│   ├── VMConfiguration.swift      VZVirtualMachineConfiguration builder
│   ├── VMImageProvider.swift      GitHub Releases image fetch + assembly
│   └── VMManager.swift            VM lifecycle, VZVirtualMachine wrapper
└── Views/
    ├── Auth/
    │   └── AuthView.swift
    ├── ContentView.swift
    ├── Library/
    │   ├── GameDetailView.swift
    │   ├── GameGridView.swift
    │   └── LibraryView.swift
    ├── Settings/
    │   └── SettingsView.swift
    └── VM/
        ├── VMProvisionView.swift
        └── VMStatusBarView.swift
```
