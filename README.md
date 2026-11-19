# Meridian

Meridian plays the Windows games in your Steam library on a Mac. It is in beta.

Download Meridian, buy a license and get support at **https://meridian.nejack.com**.

## What this repository holds

- **Releases.** Engine releases (`vX.Y.Z-engine`) hold the engine that Meridian downloads and installs by itself. The v4.3.2-engine release also holds `meridian-engine-v4.3.2-engine-source.zip`, the source that engine was built from. From Meridian's first public release, app releases (`vX.Y.Z`) hold the Meridian download.
- **The source that the open-source licenses require:** the scripts that build and package the engine, Meridian's patches to Wine and DXVK, its fork of DepotDownloader, and its stand-in for Wine's CoreMessaging DLL. The tag for each engine release (for example `v4.3.2-engine`) marks the files that engine was built from.
- **The issue tracker** for bugs and game requests.

The Meridian app's own source code is not in this repository, and this repository doesn't take pull requests. Bug reports and game requests are welcome as issues.

## Reporting a problem

Open a [new issue](https://github.com/aftrnd/meridian/issues/new/choose) and pick **Bug report** or **Game request**. Issues are public, so:

- **Never post a license key or an email address** in an issue or a comment, yours or anyone else's.
- Don't attach the diagnostics zip. It can contain Steam names, so email it to support@nejack.com with the issue number.

Questions about a purchase, a license, a refund or privacy go to support at https://meridian.nejack.com/support, not to an issue. To report a security problem, see [SECURITY.md](SECURITY.md).

## Building the engine

The engine's Wine and the libraries it loads are x86_64 and run under Rosetta 2; its DepotDownloader is an arm64 program. It is built on an Apple silicon Mac from Wine 11.0 as CodeWeavers publishes it in the CrossOver 26.3.0 source, with Meridian's patches, plus DXVK's Direct3D 9, the Khronos Vulkan loader, Mesa's KosmicKrisp driver and the libraries Wine uses. DXMT and MoltenVK are their projects' own release builds, which the scripts download. The header of each script says what it builds and why.

You need the Xcode command line tools and Homebrew, then:

```sh
brew install meson ninja cmake bison flex autoconf automake libtool mingw-w64 coreutils gh pkgconf \
             glslang llvm libclc spirv-llvm-translator spirv-tools dotnet
```

| Step | Script |
|---|---|
| x86_64 libraries: GnuTLS, nettle, GMP, FreeType, SDL2, MoltenVK, GLib, GStreamer | `Scripts/engine/build-deps.sh` |
| Wine, with the patches in `Scripts/engine/patches/wine/` | `Scripts/engine/build-wine.sh` |
| DXVK's d3d9, the Vulkan loader and KosmicKrisp | `Scripts/engine/build-d3d9.sh` |
| Assemble, relink, sign and pack the engine | `Scripts/engine/package-engine.sh` |
| Headless smoke tests | `Scripts/engine/smoke/smoke-test.sh` |

`bash Scripts/engine/publish-engine.sh vX.Y.Z-engine --no-upload` runs every step in order. Everything is built under `BUILD_ROOT`, set in `Scripts/engine/env.sh`, except DepotDownloader, which `Scripts/build-depotdownloader.sh` builds in a temporary folder. The current scripts use `/opt/meridian-engine-build`, which you make once with `sudo install -d -o "$USER" /opt/meridian-engine-build`; the scripts at the `v4.3.2-engine` tag used `~/meridian-engine-build`. `Scripts/engine/install-local.sh` installs the result into this Mac's copy of Meridian.

`package-engine.sh` also builds Meridian's DepotDownloader fork (`Scripts/build-depotdownloader.sh`, see [its README](Scripts/depotdownloader/README.md)), the CoreMessaging stand-in (`Scripts/build-coremessaging.sh`), and two small helpers that are Meridian's own code and are not published here, `meridian-dpapi.exe` and `meridian-wine-accessory.dylib`. Without those two it stops at that step. Wine, the libraries and the graphics layers build without them.

## Licenses

| Files | License |
|---|---|
| `Scripts/engine/patches/wine/`, `Scripts/engine/patches/wine-unverified/` | LGPL-2.1-or-later, like Wine |
| `Scripts/coremessaging/` | LGPL-2.1-or-later, like the Wine code it is based on |
| `Scripts/engine/patches/dxvk/` | zlib, like DXVK |
| `Scripts/depotdownloader/` | GPL-2.0, like DepotDownloader |
| Everything else (the build scripts and smoke tests) | MIT, see [LICENSE](LICENSE) |

Each of those directories has its own `LICENSE` file. The third-party components inside the engine, and their licenses, are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
