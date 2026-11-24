#!/usr/bin/env bash
#
# build-dxmt.sh — build DXMT (Direct3D 10/11 → Metal) from source, with
# Meridian's patches (patches/dxmt).
#
# Usage: bash Scripts/engine/build-dxmt.sh
#   Requires build-wine.sh to have run (see Wine below).
#   Output: $WORK/dxmt-install/{x86_64-windows,i386-windows}/*.dll and
#           x86_64-unix/winemetal.so, the layout of DXMT's release tarball.
#
# This is DXMT's own release build (its .github/workflows/ci.yml: the jobs
# setup-llvm-darwin, build-gcc-release-x86_64-windows-cross and
# build-gcc-release-x86-windows-cross), with one difference, Wine:
#
#   LLVM  DXMT's shader converter writes Metal's AIR, which is LLVM 15
#         bitcode, so winemetal.so links LLVM 15's static libraries. They are
#         built once and kept until LLVM_COMMIT changes.
#   Wine  winemetal.dll links winecrt0 statically, and winebuild marks DXMT's
#         DLLs as builtin. DXMT's CI takes both from a prebuilt Wine 8.16;
#         this takes them from the Wine the engine ships ($WORK/build-wine),
#         so the engine holds one Wine's code and its source archive one
#         Wine's source.
#
# Prerequisites: brew install meson ninja cmake mingw-w64, and Xcode with its
#   Metal toolchain (xcodebuild -downloadComponent MetalToolchain): DXMT
#   compiles its own Metal shaders at build time.

source "$(dirname "$0")/env.sh"

DXMT_REPO="https://github.com/3Shain/dxmt.git"
DXMT_VERSION="v0.80"
DXMT_COMMIT="589adb780354b461645b29999cefaf533594ee99"
LLVM_REPO="https://github.com/llvm/llvm-project.git"
LLVM_VERSION="15.0.7"
LLVM_COMMIT="8dfdcc7b7bf66834a761bd8de445840ef68e4d1a"    # llvmorg-15.0.7

OUT="$WORK/dxmt-install"
PATCHES="$(cd "$(dirname "$0")" && pwd)/patches/dxmt"
LLVM="$WORK/dxmt-llvm"
WINE_BUILD="$WORK/build-wine"

# MARK: - LLVM

build_llvm() {
    if [ "$(cat "$LLVM/meridian-commit.txt" 2>/dev/null)" = "$LLVM_COMMIT" ]; then
        say "LLVM $LLVM_VERSION: built already"
        return
    fi
    say "LLVM $LLVM_VERSION (x86_64 static libraries)"
    local src="$SRC/llvm-project" bdir="$WORK/build-dxmt-llvm"
    checkout "$LLVM_REPO" "$src" "$LLVM_COMMIT"
    rm -rf "$bdir" "$LLVM"
    cmake -S "$src/llvm" -B "$bdir" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LLVM" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DLLVM_HOST_TRIPLE=x86_64-apple-darwin -DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off \
        -DLLVM_TARGETS_TO_BUILD="" -DLLVM_BUILD_TOOLS=Off -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
        > "$WORK/dxmt-llvm-setup.log" 2>&1 \
        || { tail -20 "$WORK/dxmt-llvm-setup.log"; die "LLVM configure failed"; }
    ninja -C "$bdir" install > "$WORK/dxmt-llvm-build.log" 2>&1 \
        || { grep -m10 error: "$WORK/dxmt-llvm-build.log"; die "LLVM build failed"; }
    echo "$LLVM_COMMIT" > "$LLVM/meridian-commit.txt"
    rm -rf "$bdir"
}

# MARK: - DXMT

# meson_dxmt <32|64> <meson option>...: one of DXMT's two release builds,
# installed into $OUT.
meson_dxmt() {
    local bits="$1"; shift
    local src="$SRC/dxmt" bdir="$WORK/build-dxmt$bits"
    rm -rf "$bdir"
    meson setup --cross-file "$src/build-win$bits.txt" --buildtype release --strip --prefix "$OUT" \
        -Dwine_build_path="$WINE_BUILD" "$@" "$bdir" "$src" > "$WORK/dxmt-setup$bits.log" 2>&1 \
        || { tail -20 "$WORK/dxmt-setup$bits.log"; die "DXMT $bits-bit configure failed"; }
    meson compile -C "$bdir" > "$WORK/dxmt-build$bits.log" 2>&1 \
        || { grep -m10 error "$WORK/dxmt-build$bits.log"; die "DXMT $bits-bit build failed"; }
    meson install -C "$bdir" >> "$WORK/dxmt-build$bits.log" 2>&1 || die "DXMT $bits-bit install failed"
}

build_dxmt() {
    local src="$SRC/dxmt"
    say "DXMT $DXMT_VERSION"
    checkout "$DXMT_REPO" "$src" "$DXMT_COMMIT"
    git -C "$src" submodule -q update --init --recursive --depth 1
    apply_git_patches "$src" "$PATCHES"
    # The 64-bit build has the Unix side (winemetal.so, with the shader
    # converter); the 32-bit one is the WoW64 DLLs alone, which call into it.
    meson_dxmt 64 -Dnative_llvm_path="$LLVM" -Denable_nvapi=true -Denable_nvngx=true
    meson_dxmt 32
}

main() {
    [ -x "$WINE_BUILD/tools/winebuild/winebuild" ] || die "run build-wine.sh first"
    command -v x86_64-w64-mingw32-gcc >/dev/null || die "brew install mingw-w64"
    command -v i686-w64-mingw32-gcc   >/dev/null || die "brew install mingw-w64"
    # Metal's compiler comes with Xcode, not with the command line tools.
    xcrun -sdk macosx -f metal >/dev/null 2>&1 || export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    xcrun -sdk macosx -f metal >/dev/null 2>&1 \
        || die "no Metal compiler: install Xcode, then xcodebuild -downloadComponent MetalToolchain"
    # The checkout and the output change: publish-engine.sh's record of the
    # inputs they were built from no longer holds.
    rm -f "$WORK/stamps/dxmt.inputs"
    rm -rf "$OUT"; mkdir -p "$OUT"
    build_llvm
    build_dxmt
    local f
    for f in x86_64-windows/d3d11.dll x86_64-windows/dxgi.dll x86_64-windows/d3d10core.dll \
             x86_64-windows/winemetal.dll x86_64-unix/winemetal.so \
             i386-windows/d3d11.dll i386-windows/dxgi.dll i386-windows/d3d10core.dll i386-windows/winemetal.dll; do
        [ -f "$OUT/$f" ] || die "DXMT's build left no $f"
    done
    mkdir -p "$OUT/licenses"
    cp "$SRC/dxmt/LICENSE"                  "$OUT/licenses/dxmt-LICENSE.txt"
    cp "$SRC/llvm-project/llvm/LICENSE.TXT" "$OUT/licenses/llvm-LICENSE.txt"
    echo "DXMT $DXMT_VERSION ($DXMT_COMMIT), LLVM $LLVM_VERSION" > "$OUT/versions.txt"
    echo "DXMT $DXMT_VERSION with Meridian's patches" > "$OUT/meridian-dxmt-version.txt"
    say "DXMT built into $OUT"
}

main "$@"
