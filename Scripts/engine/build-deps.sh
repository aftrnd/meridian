#!/usr/bin/env bash
#
# build-deps.sh — cross-compile the engine's x86_64 Unix libraries from source.
#
# Usage: bash Scripts/engine/build-deps.sh [package ...]
#   No arguments builds everything in order. Each package writes a stamp file
#   under $WORK/stamps, so re-runs skip finished packages; delete the stamp to
#   rebuild one.
#
# Outputs: $DEPS/{include,lib} (x86_64, install names under $DEPS/lib — the
# packaging step rewrites them to @rpath).

source "$(dirname "$0")/env.sh"

STAMPS="$WORK/stamps"
mkdir -p "$DL" "$WORK" "$DEPS" "$STAMPS"

# Unpacks the whole tarball whenever sources/wine is missing, which is how
# publish-engine.sh gets a Wine source no earlier build has patched.
fetch_wine_sources() {
    [ -d "$SRC/wine" ] && return
    local tarball="$DL/$(basename "$WINE_SOURCE_URL")"
    if [ ! -f "$tarball" ]; then
        say "Fetching Wine source ${WINE_SOURCE_VERSION}"
        curl -fL -o "$tarball.part" "$WINE_SOURCE_URL"
        mv "$tarball.part" "$tarball"
    fi
    say "Unpacking Wine source ${WINE_SOURCE_VERSION}"
    tar -C "$BUILD_ROOT" -xzf "$tarball"
}

# Fetch an upstream tarball into $DL and unpack it into $WORK; echoes the dir.
fetch_tar() {
    local url="$1" name="${1##*/}"
    [ -f "$DL/$name" ] || curl -fsSL -o "$DL/$name" "$url"
    local dir
    dir="$(tar -tf "$DL/$name" | head -1 | cut -d/ -f1)"
    [ -d "$WORK/$dir" ] || tar -C "$WORK" -xf "$DL/$name"
    echo "$WORK/$dir"
}

# Out-of-tree autotools build of a source dir.
autotools() {
    local src="$1"; shift
    local bdir="$WORK/build-$(basename "$src")"
    [ -x "$src/configure" ] || ( cd "$src" && autoreconf -fi )
    rm -rf "$bdir"; mkdir -p "$bdir"
    ( cd "$bdir" && xcc_env && "$src/configure" $AT_HOST --prefix="$DEPS" "$@" \
        && make -j"$JOBS" && make install )
}

meson_build() {
    local src="$1"; shift
    local bdir="$WORK/build-$(basename "$src")"
    rm -rf "$bdir"
    meson setup "$bdir" "$src" --cross-file "$WORK/x86_64-darwin.cross" \
        --prefix="$DEPS" --libdir=lib --buildtype=release "$@"
    ninja -C "$bdir" -j"$JOBS" install
}

# MARK: - Packages

build_gmp() {
    # --enable-fat: runtime CPU dispatch, safe under Rosetta's x86 feature set.
    autotools "$SRC/gnutls/gmp" --enable-shared --disable-static --enable-fat
}

build_nettle() {
    # The source tarball ships nettle without Makefile.in; use the GNU release
    # of the same 3.10 line.
    local src; src="$(fetch_tar "$NETTLE_URL")"
    autotools "$src" --enable-shared --disable-static --enable-fat \
        --disable-documentation --disable-openssl
}

build_gnutls() {
    autotools "$SRC/gnutls/gnutls" --enable-shared --disable-static \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit \
        --without-idn --disable-gost --without-brotli --without-zstd --without-zlib --without-tpm --without-tpm2 \
        --disable-doc --disable-tests --disable-tools --disable-cxx --disable-nls \
        --disable-guile --disable-libdane --disable-full-test-suite \
        NETTLE_LIBS="-lnettle" HOGWEED_LIBS="-lhogweed" GMP_LIBS="-lgmp"
}

build_freetype() {
    meson_build "$SRC/freetype" -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled \
        -Dbzip2=disabled -Dzlib=internal -Dtests=disabled
}

build_sdl2() {
    local src; src="$(fetch_tar "$SDL2_URL")"
    local bdir="$WORK/build-sdl2"
    rm -rf "$bdir"
    cmake -S "$src" -B "$bdir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$DEPS" -DSDL_STATIC=OFF -DSDL_TEST=OFF
    ninja -C "$bdir" install
}

build_moltenvk() {
    # Khronos MoltenVK (Apache-2.0) from source at its release tag with
    # patches/moltenvk, and with the SPIRV-Cross revision that release pins
    # plus patches/spirv-cross (the patches say why). It builds as its release
    # does, with Xcode: MoltenVK's script fetches the libraries it links at
    # the revisions it pins and builds them, taking SPIRV-Cross from the
    # patched checkout, then `make macos` makes the universal dylib. The engine
    # keeps the x86_64 slice. Vulkan's headers come from the same build.
    local version="1.4.2" commit="db66022459ffb663aa2b50f6b018bc2e124f5edf"    # v1.4.2
    # The checkouts are named apart from the moltenvk folder that the Wine
    # source tarball unpacks.
    local src="$SRC/moltenvk-git" cross="$SRC/spirv-cross-git" patches
    patches="$(cd "$(dirname "$0")" && pwd)/patches"
    xcodebuild -version >/dev/null 2>&1 || export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    xcodebuild -version >/dev/null 2>&1 || die "MoltenVK builds with Xcode: install it"
    checkout "https://github.com/KhronosGroup/MoltenVK.git" "$src" "$commit"
    apply_git_patches "$src" "$patches/moltenvk"
    checkout "https://github.com/KhronosGroup/SPIRV-Cross.git" "$cross" "$(cat "$src/ExternalRevisions/SPIRV-Cross_repo_revision")"
    apply_git_patches "$cross" "$patches/spirv-cross"
    # Xcode's own tools, not the GNU ones env.sh puts first on PATH, and
    # MoltenVK's own deployment target.
    local xcode_env=(env -u MACOSX_DEPLOYMENT_TARGET PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    ( cd "$src" && "${xcode_env[@]}" ./fetchDependencies --macos --spirv-cross-root "$cross" > "$WORK/moltenvk-libraries.log" 2>&1 ) \
        || { tail -20 "$WORK/moltenvk-libraries.log"; die "MoltenVK's libraries failed to build"; }
    ( cd "$src" && "${xcode_env[@]}" make macos > "$WORK/moltenvk-build.log" 2>&1 ) \
        || { grep -m10 error: "$WORK/moltenvk-build.log"; die "MoltenVK $version failed to build"; }
    local dylib="$src/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
    [ -f "$dylib" ] || die "MoltenVK's build left no libMoltenVK.dylib"
    mkdir -p "$DEPS/lib" "$DEPS/include"
    lipo "$dylib" -thin x86_64 -output "$DEPS/lib/libMoltenVK.dylib"
    install_name_tool -id "$DEPS/lib/libMoltenVK.dylib" "$DEPS/lib/libMoltenVK.dylib"
    cp -R "$src/Package/Release/MoltenVK/include/"* "$DEPS/include/"
}

build_glib() {
    # The tarball's glib 2.78 tree lacks the gvdb submodule, and 2.78's
    # gdbus-codegen needs Python's removed distutils. Upstream 2.82 has
    # neither problem and satisfies GStreamer 1.24 (>= 2.64). libffi, pcre2
    # and libintl come from glib's own meson wraps.
    local src; src="$(fetch_tar "$GLIB_URL")"
    meson_build "$src" -Dtests=false -Dinstalled_tests=false -Dnls=disabled \
        -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
        -Dsysprof=disabled -Ddtrace=disabled -Dlibelf=disabled -Dman-pages=disabled \
        -Ddocumentation=false -Dglib_debug=disabled \
        --force-fallback-for=libffi,pcre2,proxy-libintl
}

build_gstreamer() {
    # winegstreamer's Media Foundation / DirectShow decode path. The plugin set
    # matches what Meridian engines have shipped: container demuxers (mp4, avi,
    # asf, wav), parsers, converters, and applemedia's VideoToolbox decoders.
    # ORC is off: a cross build needs a native `orcc`, and every element has a
    # plain-C fallback (video decode itself runs in VideoToolbox).
    meson_build "$SRC/gstreamer" -Dauto_features=disabled \
        -Dbase=enabled -Dgood=enabled -Dbad=enabled -Dugly=enabled \
        -Dlibav=disabled -Dtests=disabled -Dexamples=disabled -Ddoc=disabled \
        -Dintrospection=disabled -Dpython=disabled -Ddevtools=disabled -Dges=disabled \
        -Drtsp_server=disabled -Dsharp=disabled -Dvaapi=disabled -Dlibnice=disabled \
        -Dtools=disabled -Dorc=disabled -Dbuild-tools-source=system \
        -Dgstreamer:tools=disabled -Dgstreamer:check=disabled -Dgstreamer:coretracers=disabled \
        -Dgst-plugins-base:app=enabled -Dgst-plugins-base:audioconvert=enabled \
        -Dgst-plugins-base:audioresample=enabled -Dgst-plugins-base:playback=enabled \
        -Dgst-plugins-base:typefind=enabled -Dgst-plugins-base:videoconvertscale=enabled \
        -Dgst-plugins-base:gl=enabled -Dgst-plugins-base:gl_api=opengl \
        -Dgst-plugins-base:gl_platform=cgl -Dgst-plugins-base:gl_winsys=cocoa \
        -Dgst-plugins-good:audioparsers=enabled -Dgst-plugins-good:avi=enabled \
        -Dgst-plugins-good:deinterlace=enabled -Dgst-plugins-good:id3demux=enabled \
        -Dgst-plugins-good:isomp4=enabled -Dgst-plugins-good:videofilter=enabled \
        -Dgst-plugins-good:wavparse=enabled \
        -Dgst-plugins-bad:applemedia=enabled -Dgst-plugins-bad:videoparsers=enabled \
        -Dgst-plugins-bad:gl=enabled \
        -Dgst-plugins-ugly:asfdemux=enabled
}

ALL=(gmp nettle gnutls freetype sdl2 moltenvk glib gstreamer)

main() {
    command -v meson >/dev/null || die "meson missing: brew install meson ninja cmake bison flex"
    fetch_wine_sources
    write_meson_cross
    local pkgs=("$@"); [ ${#pkgs[@]} -gt 0 ] || pkgs=("${ALL[@]}")
    for p in "${pkgs[@]}"; do
        if [ -f "$STAMPS/$p" ] && [ $# -eq 0 ]; then say "$p: already built"; continue; fi
        # $DEPS changes: publish-engine.sh's record of its inputs no longer holds.
        rm -f "$STAMPS/deps.inputs"
        say "Building $p"
        "build_$p"
        touch "$STAMPS/$p"
    done
    say "Dependencies installed in $DEPS"
}

main "$@"
