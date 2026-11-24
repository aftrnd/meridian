#!/usr/bin/env bash
#
# package-engine.sh — assemble the Meridian engine tarball from source-built parts.
#
# Usage: bash Scripts/engine/package-engine.sh <vX.Y.Z-engine>
#   Requires build-deps.sh, build-wine.sh, build-dxmt.sh and build-d3d9.sh to have run.
#   Produces $BUILD_ROOT/meridian-engine-arm64.tar.gz (the asset EngineDownloader
#   installs into ~/Library/Application Support/com.meridian.app/engine/).
#   Publishing is a separate step: Scripts/engine/publish-engine.sh.
#
# Nothing here is taken from an installed product. Components:
#   Wine        published LGPL-2.1 source + Meridian's patches       build-wine.sh
#   libraries   GnuTLS, nettle, gmp, freetype, SDL2, GLib, GStreamer   build-deps.sh
#   MoltenVK    Khronos release (Apache-2.0)                           build-deps.sh
#   DXMT        3Shain/dxmt (MIT) + Meridian's patches, with LLVM 15    build-dxmt.sh
#   DXVK d3d9, Vulkan-Loader, KosmicKrisp (zlib, Apache-2.0, MIT)       build-d3d9.sh
#   DepotDownloader  Meridian's fork (GPL-2.0), from source every time  build-depotdownloader.sh
#
# licenses/ holds the license texts of the main components and README.txt,
# which names the public source: the scripts and patches tagged in
# $ENGINE_REPO, and the release's source archive (publish-engine.sh).
#
# Renderer selection (no closed renderer switch):
#   Wine searches its own lib/wine before any WINEDLLPATH entry, so a DLL that
#   exists there can never be overridden per launch. The D3D front-end DLLs that
#   Meridian switches between are therefore moved OUT of lib/wine into one
#   directory per implementation. WineEngine builds each launch's search path
#   as  <preferred backend>:lib/wined3d:lib/wine  so Wine's own implementation
#   fills in whatever the preferred backend does not provide:
#     lib/dxmt/    d3d11 dxgi d3d10core (+ nvapi64, nvngx)   D3D10/11 → Metal
#     lib/dxvk/    d3d9                                       D3D9 → Vulkan → KosmicKrisp → Metal
#     lib/wined3d/ d3d9 d3d11 dxgi d3d10core d3d12 d3d12core  Wine's own
#   DXMT's backend, winemetal.dll/.so, links Wine's winemac.so via @loader_path
#   and has no Wine counterpart, so it lives in lib/wine itself. DXVK's Vulkan
#   goes through lib64/libvulkan.1.dylib (WINE_VULKAN_LIBRARY, patch 0009),
#   which loads KosmicKrisp from lib64/kosmickrisp_icd.json (VK_DRIVER_FILES).
#
# Game Mode: lib/wine/x86_64-unix/Meridian Game.app is the bundle games run
# from (stage_game_bundle; Wine patch 0013).
#
# Not shipped: Apple D3DMetal (GPTK license), cxcompatdb.so (closed source),
# the gbe_fork Steamworks emulator, and any Valve binary.

source "$(dirname "$0")/env.sh"

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-engine$ ]] || die "usage: package-engine.sh vX.Y.Z-engine"

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
WINE_INSTALL="$WORK/wine-install"
ARCHIVE="$BUILD_ROOT/meridian-engine-arm64.tar.gz"
# The D3D front-ends Meridian switches between per launch. d3d12 moves too:
# while it sits in lib/wine nothing on WINEDLLPATH can ever replace it.
SWITCHED_DLLS=(d3d9 d3d11 dxgi d3d10core d3d12 d3d12core)
DXMT_INSTALL="$WORK/dxmt-install"
D3D9_INSTALL="$WORK/d3d9-install"
GAME_BUNDLE="Meridian Game.app"    # the name patch 0013 looks for beside the loader

W="$STAGE/wine"

# MARK: - Wine

stage_wine() {
    say "Staging Wine $("$WINE_INSTALL/bin/wine" --version)"
    rm -rf "$STAGE"; mkdir -p "$W"
    cp -R "$WINE_INSTALL/bin" "$WINE_INSTALL/lib" "$WINE_INSTALL/share" "$W/"
    # The app launches bin/wine64 (historical name); Wine 11 has one loader.
    cp "$W/bin/wine" "$W/bin/wine64"

    # Wine's PE side builds with -g and keeps COFF symbol tables; without
    # stripping, every DLL (and its copy in the prefix template's system32)
    # is ~1.5x larger. Exports live in the export table, not the symbol
    # table, and strip keeps the "Wine builtin DLL" marker.
    say "Stripping symbols"
    find "$W/lib/wine/x86_64-windows" -type f ! -name '*.a' -print0 \
        | xargs -0 x86_64-w64-mingw32-strip -s 2>/dev/null || true
    find "$W/lib/wine/i386-windows" -type f ! -name '*.a' -print0 \
        | xargs -0 i686-w64-mingw32-strip -s 2>/dev/null || true
    find "$W/lib/wine/x86_64-unix" -type f -print0 | xargs -0 strip -x 2>/dev/null || true
    strip -x "$W/bin/wine" "$W/bin/wine64" "$W/bin/wineserver"

    say "Moving Wine's D3D front-ends to lib/wined3d"
    local arch dll
    for arch in x86_64-windows i386-windows; do
        mkdir -p "$W/lib/wined3d/$arch"
        for dll in "${SWITCHED_DLLS[@]}"; do
            mv "$W/lib/wine/$arch/$dll.dll" "$W/lib/wined3d/$arch/"
        done
    done
}

# MARK: - DXMT

stage_dxmt() {
    say "Staging DXMT"
    local src="$DXMT_INSTALL" arch dll
    for arch in x86_64-windows i386-windows; do
        mkdir -p "$W/lib/dxmt/$arch"
        for dll in "$src/$arch"/*.dll; do
            case "$(basename "$dll")" in
                winemetal.dll) cp "$dll" "$W/lib/wine/$arch/" ;;
                *)             cp "$dll" "$W/lib/dxmt/$arch/" ;;
            esac
        done
    done
    cp "$src/x86_64-unix/winemetal.so" "$W/lib/wine/x86_64-unix/"
    cp "$src/meridian-dxmt-version.txt" "$W/"
}

# MARK: - D3D9

# DXVK's d3d9 in lib/dxvk; the Vulkan loader, KosmicKrisp and its manifest in
# lib64 (build-d3d9.sh). Before stage_libraries, which relinks and rpaths
# every dylib in the tree.
stage_d3d9() {
    say "Staging the D3D9 path ($(cat "$D3D9_INSTALL/versions.txt"))"
    local arch dll strip
    for arch in x86_64-windows i386-windows; do
        mkdir -p "$W/lib/dxvk/$arch"
        dll="$W/lib/dxvk/$arch/d3d9.dll"
        cp "$D3D9_INSTALL/dxvk/$arch/d3d9.dll" "$dll"
        strip=$([ "$arch" = i386-windows ] && echo i686-w64-mingw32-strip || echo x86_64-w64-mingw32-strip)
        "$strip" -s "$dll"
        mark_builtin "$dll"
    done
    mkdir -p "$W/lib64"
    cp "$D3D9_INSTALL"/lib64/* "$W/lib64/"
    cp "$D3D9_INSTALL/versions.txt" "$W/meridian-d3d9-version.txt"
}

# Wine loads a DLL from its own directories only when the DOS stub says
# "Wine builtin DLL" at 0x40 (what winebuild --builtin writes); DXVK's
# MinGW build doesn't, and Wine would skip it without a word.
mark_builtin() {
    python3 -I - "$1" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
assert struct.unpack_from("<I", d, 0x3C)[0] >= 0x40 + 32, "no room in the DOS stub: " + p
d[0x40:0x40 + 17] = b"Wine builtin DLL\0"
open(p, "wb").write(d)
PY
}

# MARK: - Libraries

# Copy the x86_64 dylibs Wine loads into wine/lib64 and rewrite every
# reference to the build prefix into @rpath, so the tree is relocatable.
stage_libraries() {
    say "Staging libraries into wine/lib64"
    mkdir -p "$W/lib64/gstreamer-1.0"
    local f
    for f in "$DEPS"/lib/*.dylib; do
        [ -L "$f" ] && continue           # real files only; links recreated below
        cp "$f" "$W/lib64/"
    done
    # Recreate the versioned symlinks that dlopen() and the linker use.
    for f in "$DEPS"/lib/*.dylib; do
        [ -L "$f" ] || continue
        ln -sf "$(readlink "$f")" "$W/lib64/$(basename "$f")"
    done
    cp "$DEPS"/lib/gstreamer-1.0/*.dylib "$W/lib64/gstreamer-1.0/"

    say "Rewriting install names to @rpath"
    local bin
    while IFS= read -r bin; do
        relink "$bin"
    done < <(find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) ; echo "$W/bin/wine"; echo "$W/bin/wine64"; echo "$W/bin/wineserver")
    # Wine's own Unix modules find lib64 through this rpath.
    for bin in "$W"/lib/wine/x86_64-unix/*.so; do
        add_rpath "$bin" "@loader_path/../../../lib64"
    done
    for bin in "$W"/lib64/*.dylib; do
        [ -L "$bin" ] || add_rpath "$bin" "@loader_path"
    done
    for bin in "$W"/lib64/gstreamer-1.0/*.dylib; do
        add_rpath "$bin" "@loader_path/.."
    done
    # Absolute rpaths point into the build tree. winegstreamer.so kept
    # $DEPS/lib ahead of lib64, so on the build Mac the game loaded a second
    # GStreamer/GLib next to the bundled one: plugins registered in one copy,
    # Wine queried the other, and videos rendered black (Oct 8 2026).
    say "Removing absolute rpaths"
    local rp
    while IFS= read -r bin; do
        file "$bin" | grep -q 'Mach-O' || continue
        while IFS= read -r rp; do
            install_name_tool -delete_rpath "$rp" "$bin"
        done < <(otool -l "$bin" | awk '/LC_RPATH/{getline;getline;print $2}' | grep '^/')
    done < <(find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) ; echo "$W/bin/wine"; echo "$W/bin/wine64"; echo "$W/bin/wineserver")
    if find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) -exec otool -l {} + 2>/dev/null \
        | awk '/LC_RPATH/{getline;getline;print $2}' | grep -q '^/'; then
        die "absolute rpath left in the engine"
    fi
}

relink() {
    local bin="$1" dep
    file "$bin" | grep -q 'Mach-O' || return 0
    case "$bin" in "$W"/lib64/*.dylib)
        install_name_tool -id "@rpath/$(basename "$bin")" "$bin" 2>/dev/null ;;
    esac
    while IFS= read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$bin" 2>/dev/null
    done < <(otool -L "$bin" | awk 'NR>1 {print $1}' | grep "^$DEPS/")
}

add_rpath() {
    otool -l "$1" | grep -A2 LC_RPATH | grep -q "path $2 " \
        || install_name_tool -add_rpath "$2" "$1" 2>/dev/null
}

# MARK: - Meridian tools

stage_meridian_tools() {
    say "Building Meridian's Wine-side helpers"
    mkdir -p "$W/share/meridian" "$STAGE/tools"
    bash "$SCRIPTS/build-coremessaging.sh" "$W/lib/wine/x86_64-windows/coremessaging.dll"
    bash "$SCRIPTS/build-dpapi.sh" "$W/share/meridian/meridian-dpapi.exe"
    bash "$SCRIPTS/build-wine-accessory.sh" "$W/share/meridian/meridian-wine-accessory.dylib"

    # Meridian's fork (GPL-2.0), built from the upstream commit and patch the
    # source archive carries, with its license notices. Never a copy of some
    # other binary: its source couldn't be offered.
    local dd="$STAGE/tools/depotdownloader/DepotDownloader"
    mkdir -p "$(dirname "$dd")"
    bash "$SCRIPTS/build-depotdownloader.sh" "$dd" "$STAGE/licenses/depotdownloader"
}

# MARK: - Signing

sign_loader() {
    # Ad-hoc sign the loader with the entitlements Meridian relies on:
    # DYLD_INSERT_LIBRARIES (wine-accessory) and JIT-style memory for games.
    say "Signing Wine loader"
    local ent="$WORK/wine-entitlements.plist"
    cat > "$ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
EOF
    local bin
    for bin in "$W/bin/wine" "$W/bin/wine64" "$W/lib/wine/x86_64-unix/wine"; do
        codesign --force --sign - --entitlements "$ent" "$bin"
    done
    # Everything else install_name_tool touched needs a fresh ad-hoc signature.
    find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) -exec codesign --force --sign - {} + 2>/dev/null
    codesign --force --sign - "$W/bin/wineserver"
}

# MARK: - Game bundle

# macOS gives Game Mode to a process whose executable is inside an app bundle
# that says it is a game, so games run from this one (patch 0013 puts a copy
# of the loader in it for every executable in a Steam library). The loader's
# signature covers its embedded Info.plist, and run from inside a bundle it
# must find the same bytes in Contents/Info.plist: the file is that section,
# taken out of the loader. The loader opens ntdll.so beside itself.
stage_game_bundle() {
    say "Staging the game bundle"
    local unix="$W/lib/wine/x86_64-unix"
    mkdir -p "$unix/$GAME_BUNDLE/Contents/MacOS"
    segedit "$unix/wine" -extract __TEXT __info_plist "$unix/$GAME_BUNDLE/Contents/Info.plist"
    ln -s ../../../ntdll.so "$unix/$GAME_BUNDLE/Contents/MacOS/ntdll.so"
}

# MARK: - Prefix template

engine_env() {
    # Same search path as the app's default (WineEngine.dllSearchPath):
    # wineboot only puts system32 placeholders in for DLLs it finds here, and
    # Wine never loads a DLL that has neither a placeholder nor a file in the
    # game folder. Without lib/wined3d, d3d12/d3d12core had no placeholder and
    # every Unity 6 game crashed on UnityPlayer's delay-load of d3d12.dll
    # (0xc06d007e, status c0000135; No, I'm not a Human, Oct 7 2026).
    env -i HOME="$HOME" PATH="/usr/bin:/bin" \
        WINEPREFIX="$1" WINEDEBUG=-all WINEMSYNC=1 MVK_CONFIG_LOG_LEVEL=0 \
        WINEDLLPATH="$W/lib/dxmt:$W/lib/wined3d:$W/lib/wine" \
        WINEDLLOVERRIDES="mscoree,mshtml=" \
        "${@:2}"
}

build_prefix_template() {
    # mscoree/mshtml disabled: wineboot must never prompt for Wine Mono/Gecko.
    say "Building prefix template (wineboot --init)"
    local tpl="$WORK/prefix-template" timeout
    timeout="$(command -v gtimeout || command -v timeout)" || die "brew install coreutils (gtimeout)"
    rm -rf "$tpl"
    engine_env "$tpl" "$timeout" 300 "$W/bin/wine64" wineboot --init \
        || die "wineboot --init failed or timed out"
    engine_env "$tpl" "$W/bin/wineserver" -w

    local dlls services
    dlls=$(find "$tpl/drive_c/windows/system32" -name '*.dll' | wc -l | tr -d ' ')
    services=$(grep -cE '^\[System\\\\(CurrentControlSet|ControlSet001)\\\\Services\\\\[^\\]+\]' "$tpl/system.reg" || true)
    [ "$dlls" -gt 100 ] || die "prefix template has only $dlls DLLs"
    # steamwebhelper networking needs the full wine.inf service registration.
    grep -q Winsock2 "$tpl/system.reg" || die "prefix template missing Winsock2 registration"
    grep -q Dnscache "$tpl/system.reg" || die "prefix template missing Dnscache registration"
    [ "$services" -ge 15 ] || die "prefix template has only $services services"
    [ -f "$tpl/drive_c/windows/system32/d3d12.dll" ] || die "prefix template missing d3d12.dll (Unity 6 delay-loads it)"
    [ -f "$tpl/drive_c/windows/syswow64/d3d9.dll" ] || die "prefix template missing the 32-bit d3d9.dll placeholder"
    echo "    template: $dlls DLLs, $services services"

    scrub_template "$tpl"
    rm -rf "$tpl/dosdevices"; mkdir -p "$tpl/dosdevices" "$tpl/drive_c/windows/syswow64"
    cp -R "$tpl" "$STAGE/prefix-template"
}

# wineboot records the Mac it runs on in the prefix, and the template ships
# to every player. Wine writes each of these again on the player's Mac:
# - drive_c/users/steamuser/{Documents,Music,Pictures,Videos,Downloads} are
#   absolute links into the packager's home folder (broken links everywhere
#   else). shell32 links a missing one into the running user's home when a
#   program asks for it with CSIDL_FLAG_CREATE (_SHCreateSymbolicLink,
#   shellpath.c). Desktop/My Mac Desktop doesn't come back: shell32 makes it
#   only for a missing Desktop folder, and the template has one.
# - Wine's own fonts (share/wine/fonts) are listed as external fonts by their
#   path in the build folder, and so are fonts the packager installed for
#   their own account, by their path in the home folder (four Adobe fonts,
#   Nov 24 2026). win32u drops a listed font this Mac doesn't have and lists
#   the ones it has at every session start (update_external_font_keys,
#   font.c).
# - The host name: ComputerName, Tcpip's Hostname and Domain, and USERDOMAIN
#   and LOGONSERVER in Volatile Environment. Every session starts with
#   wineboot --init (run_wineboot, ntdll's unix/env.c), which writes them
#   before the first program runs (create_computer_name_keys and
#   create_volatile_environment_registry_key, wineboot.c).
# - The GPU and the displays: the GPU's name, and each display's EDID with
#   its serial number. A session's first display query finds no
#   HARDWARE\DEVICEMAP\VIDEO (a volatile key), asks the Mac driver, and
#   prepare_devices (win32u's sysparams.c) empties these keys before it adds
#   the player's own.
scrub_template() {
    local tpl="$1" reg
    find "$tpl/drive_c/users" -type l -delete
    for reg in "$tpl"/*.reg; do
        BUILD_PATH="$(reg_path "$BUILD_ROOT")" HOME_PATH="$(reg_path "$HOME")" \
            awk "$SCRUBBED_ENTRIES" "$reg" > "$reg.new"
        mv "$reg.new" "$reg"
    done
}

# The registry entries scrub_template drops: device keys whole, the other
# entries value by value (a value spans the lines that end in a backslash).
# Key paths are compared in lower case, with / for the .reg file's \\.
SCRUBBED_ENTRIES='
/^\[/ {
    key = tolower($0); sub(/^\[/, "", key); sub(/\]( [0-9]+)?$/, "", key); gsub(/\\\\/, "/", key)
    device = key ~ /^system\/controlset001\/(enum\/(display|pci)|control\/class\/[{]4d36e96[8e]-e325-11ce-bfc1-08002be10318[}])\//
    cont = 0
}
device { next }
cont { cont = /\\$/; if (!drop) print; next }
/^["@]/ {
    name = tolower($0); sub(/=.*/, "", name)
    drop = index($0, ENVIRON["BUILD_PATH"]) || index($0, ENVIRON["HOME_PATH"]) \
        || (key == "system/controlset001/control/computername/computername" && name == "\"computername\"") \
        || (key == "system/controlset001/services/tcpip/parameters" && (name == "\"hostname\"" || name == "\"domain\"")) \
        || (key == "volatile environment" && (name == "\"userdomain\"" || name == "\"logonserver\""))
    cont = /\\$/
    if (!drop) print
    next
}
{ print }
'

# A Unix path as a .reg file stores it: Z:\\Users\\name (backslashes doubled).
reg_path() { printf 'Z:%s' "$1" | sed 's|/|\\\\|g'; }

# MARK: - Licenses

# One license text into licenses/. A text an upstream has moved stops the
# package: the engine never ships without it.
license() {
    [ -f "$2" ] || die "license text missing: $2"
    cp "$2" "$STAGE/licenses/$1"
}

stage_licenses() {
    say "Staging license texts"
    local d="$STAGE/licenses" nettle glib lib f
    nettle="$(unpacked "$NETTLE_URL")"
    glib="$(unpacked "$GLIB_URL")"
    mkdir -p "$d/wine-libs"
    license wine-LGPL-2.1.txt               "$SRC/wine/COPYING.LIB"
    license wine-LICENSE.txt                "$SRC/wine/LICENSE"
    # The libraries Wine builds into its own modules (libs/: FAudio, libpng, ...).
    for lib in "$SRC"/wine/libs/*/; do
        for f in "$lib"COPYING* "$lib"COPYRIGHT* "$lib"LICEN[CS]E*; do
            if [ -f "$f" ]; then cp "$f" "$d/wine-libs/$(basename "$lib")-$(basename "$f")"; fi
        done
    done
    cp "$DXMT_INSTALL"/licenses/* "$d/"
    license moltenvk-LICENSE.txt            "$WORK/MoltenVK/LICENSE"
    cp "$D3D9_INSTALL"/licenses/* "$d/"
    license gnutls-LICENSE.txt              "$SRC/gnutls/gnutls/LICENSE"
    license gnutls-LGPL-2.1.txt             "$SRC/gnutls/gnutls/doc/COPYING.LESSER"
    license gnutls-GPL-3.0.txt              "$SRC/gnutls/gnutls/doc/COPYING"
    license nettle-LGPL-3.0.txt             "$nettle/COPYING.LESSERv3"
    license nettle-GPL-3.0.txt              "$nettle/COPYINGv3"
    license nettle-GPL-2.0.txt              "$nettle/COPYINGv2"
    license gmp-LGPL-3.0.txt                "$SRC/gnutls/gmp/COPYING.LESSERv3"
    license gmp-GPL-3.0.txt                 "$SRC/gnutls/gmp/COPYINGv3"
    license gmp-GPL-2.0.txt                 "$SRC/gnutls/gmp/COPYINGv2"
    license freetype-LICENSE.txt            "$SRC/freetype/LICENSE.TXT"
    license freetype-FTL.txt                "$SRC/freetype/docs/FTL.TXT"
    license sdl2-LICENSE.txt                "$(unpacked "$SDL2_URL")/LICENSE.txt"
    license glib-LGPL-2.1.txt               "$glib/COPYING"
    license glib-proxy-libintl-COPYING.txt  "$glib/subprojects/proxy-libintl/COPYING"
    license glib-libffi-LICENSE.txt         "$glib/subprojects/libffi/LICENSE"
    license glib-pcre2-LICENCE.txt          "$glib"/subprojects/pcre2-*/LICENCE
    license gstreamer-LGPL-2.1.txt          "$SRC/gstreamer/LICENSE"
    [ -f "$d/depotdownloader/NOTICES.txt" ] || die "DepotDownloader's notices are missing (stage_meridian_tools)"

    cat > "$d/README.txt" <<EOF
Meridian engine $TAG: third-party components

Wine 11.0 (source ${WINE_SOURCE_VERSION} as published by CodeWeavers)  LGPL-2.1
  Source: ${WINE_SOURCE_URL}
  Meridian's changes: Scripts/engine/patches/wine/
  Libraries Wine builds into its modules: wine-libs/
DXMT (Meridian's patches/dxmt applied)             MIT        https://github.com/3Shain/dxmt
LLVM (built into DXMT's winemetal.so)              Apache-2.0 with LLVM exceptions  https://llvm.org
  Revisions: $(cat "$DXMT_INSTALL/versions.txt")
MoltenVK 1.4.2                                     Apache-2.0 https://github.com/KhronosGroup/MoltenVK
DXVK (d3d9; Meridian's patches/dxvk applied)       zlib       https://github.com/doitsujin/dxvk
Vulkan-Loader                                      Apache-2.0 https://github.com/KhronosGroup/Vulkan-Loader
Mesa KosmicKrisp                                   MIT        https://gitlab.freedesktop.org/mesa/mesa
  Revisions: $(cat "$D3D9_INSTALL/versions.txt")
GnuTLS                                             LGPL-2.1+  https://gnutls.org
  With its bundled libtasn1 (LGPL-2.1+) and libunistring (LGPL-3.0+ or GPL-2.0+)
GMP                                                LGPL-3.0+ or GPL-2.0+  https://gmplib.org
FreeType                                           FTL        https://freetype.org
GStreamer                                          LGPL-2.1   https://gstreamer.freedesktop.org
  GnuTLS, GMP, FreeType and GStreamer are built from the copies in the
  CrossOver source above (${WINE_SOURCE_URL##*/}).
nettle                                             LGPL-3.0+ or GPL-2.0+  https://www.lysator.liu.se/~nisse/nettle/
  Source: ${NETTLE_URL}
SDL2                                               zlib       https://libsdl.org
  Source: ${SDL2_URL}
GLib                                               LGPL-2.1+  https://gitlab.gnome.org/GNOME/glib
  Source: ${GLIB_URL}
  Built with proxy-libintl (LGPL-2.0), libffi (MIT) and PCRE2 (BSD)
DepotDownloader (Meridian fork)                    GPL-2.0    https://github.com/SteamRE/DepotDownloader
  Its .NET runtime and NuGet packages: depotdownloader/NOTICES.txt

Wine is built from the cited source with Meridian's patches applied, and
DepotDownloader with Meridian's patch. The LGPL libraries in wine/lib64 are
built unmodified from the sources named above and loaded dynamically.

Source
  Build scripts and patches:
    https://github.com/${ENGINE_REPO}/tree/$TAG/Scripts/engine
  The source of the LGPL and GPL components, as built:
    $(source_zip_name "$TAG"), attached to
    https://github.com/${ENGINE_REPO}/releases/tag/$TAG
EOF
}

# MARK: - Validate & archive

validate() {
    say "Validating"
    local f
    for f in bin/wine64 bin/wineserver share/wine/wine.inf share/wine/winmd/windows.system.winmd \
             share/wine/nls/l_intl.nls share/wine/nls/locale.nls share/wine/nls/normnfc.nls \
             lib/wine/x86_64-unix/winemetal.so lib/wine/x86_64-windows/winemetal.dll \
             lib/dxmt/x86_64-windows/d3d11.dll lib/dxmt/i386-windows/d3d11.dll \
             lib/wined3d/x86_64-windows/d3d11.dll lib/wined3d/i386-windows/d3d11.dll \
             lib/wined3d/x86_64-windows/d3d9.dll lib/wined3d/i386-windows/d3d9.dll \
             lib/dxvk/x86_64-windows/d3d9.dll lib/dxvk/i386-windows/d3d9.dll \
             lib64/libvulkan.1.dylib lib64/libvulkan_kosmickrisp.dylib lib64/kosmickrisp_icd.json \
             lib64/libgnutls.30.dylib lib64/libMoltenVK.dylib lib64/libfreetype.6.dylib; do
        [ -e "$W/$f" ] || die "missing wine/$f"
    done
    local game="$W/lib/wine/x86_64-unix/$GAME_BUNDLE/Contents"
    [ "$(plutil -extract LSApplicationCategoryType raw "$game/Info.plist")" = public.app-category.games ] \
        && [ "$(plutil -extract GCSupportsGameMode raw "$game/Info.plist")" = true ] \
        || die "the game bundle's Info.plist doesn't say it is a game (patch 0013)"
    # With a name in it, the Dock would call every game by that name.
    ! plutil -extract CFBundleName raw "$game/Info.plist" >/dev/null 2>&1 \
        || die "the game bundle's Info.plist has a CFBundleName"
    [ "$game/MacOS/ntdll.so" -ef "$W/lib/wine/x86_64-unix/ntdll.so" ] || die "the game bundle's ntdll.so link is broken"
    for f in "${SWITCHED_DLLS[@]}"; do
        [ ! -e "$W/lib/wine/x86_64-windows/$f.dll" ] || die "$f.dll still in lib/wine (would shadow WINEDLLPATH)"
    done
    # No absolute build paths may survive in the shipped Mach-O files.
    local leaks
    leaks=$(find "$W" -type f \( -name '*.dylib' -o -name '*.so' \) -exec otool -L {} + 2>/dev/null \
        | grep $'^\t' | grep -c "$BUILD_ROOT" || true)
    [ "$leaks" -eq 0 ] || die "$leaks library references still point into $BUILD_ROOT"
    ! find "$STAGE" -name 'cxcompatdb*' -o -name 'D3DMetal*' | grep -q . || die "closed-source component in stage"

    # The tarball is public: nothing in it may name the packager's home
    # folder (a compiled-in path, a registry value), point a link outside the
    # engine, or keep a registry value in the build folder.
    leaks=$(grep -rlF -e "$HOME" -e "$(reg_path "$HOME")" "$STAGE" | head -5 || true)
    [ -z "$leaks" ] || die "the engine names $HOME (BUILD_ROOT must be outside it):"$'\n'"$leaks"
    leaks=$(find "$STAGE" -type l -lname '/*' | head -5 || true)
    [ -z "$leaks" ] || die "absolute symlinks in the engine:"$'\n'"$leaks"
    leaks=$(grep -lF "$(reg_path "$BUILD_ROOT")" "$STAGE"/prefix-template/*.reg || true)
    [ -z "$leaks" ] || die "registry values still point into $BUILD_ROOT:"$'\n'"$leaks"

    # Nor may the prefix template name this Mac (scrub_template): its user
    # name, its short host name or the 15-character computer name Wine makes
    # of it, in any case, in a text file (the registry, .ini, .inf) or a
    # file's name, or keep a display's EDID. The binaries are Wine's build
    # output, which the $HOME check covers; a name search there finds the
    # authors' names in shell32's About box.
    local tpl="$STAGE/prefix-template" host user
    host="$(hostname -s)"; user="$(id -un)"
    leaks=$( { grep -rliwIF -e "$user" -e "$host" -e "${host:0:15}" "$tpl"
               find "$tpl" -iname "$user" -o -iname "*${host:0:15}*"; } | head -5 || true)
    [ -z "$leaks" ] || die "the prefix template names this Mac (user or host name):"$'\n'"$leaks"
    ! grep -qi '^"EDID"=' "$tpl/system.reg" || die "the prefix template keeps a display's EDID"
}

main() {
    [ -x "$WINE_INSTALL/bin/wine" ] || die "run build-wine.sh first"
    [ -f "$DXMT_INSTALL/versions.txt" ] || die "run build-dxmt.sh first"
    [ -f "$D3D9_INSTALL/versions.txt" ] || die "run build-d3d9.sh first"
    command -v dotnet >/dev/null || die "brew install dotnet: DepotDownloader is built from source for every engine"
    stage_wine
    stage_dxmt
    stage_d3d9
    stage_libraries
    stage_meridian_tools
    sign_loader
    stage_game_bundle
    echo "$TAG" > "$W/meridian-engine-version.txt"
    build_prefix_template
    stage_licenses
    validate

    say "Creating $ARCHIVE"
    rm -f "$ARCHIVE"
    tar -C "$STAGE" -czf "$ARCHIVE" .
    du -sh "$ARCHIVE"
}

main "$@"
