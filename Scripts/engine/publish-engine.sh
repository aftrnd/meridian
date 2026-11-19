#!/usr/bin/env bash
#
# publish-engine.sh: build, smoke-test and publish a Meridian engine release.
#
# Usage: bash Scripts/engine/publish-engine.sh vX.Y.Z-engine [--no-upload]
#
# Builds the engine from the commit checked out, smoke-tests it, then
# publishes the release that EngineDownloader installs from, in the public
# repository ($ENGINE_REPO). --no-upload stops after the smoke test and
# leaves the tarball at $BUILD_ROOT/meridian-engine-arm64.tar.gz: the build
# an upload of the same commit would publish, and reuses.
#
#   1. build-deps.sh      x86_64 libraries
#   2. build-wine.sh      Wine from its published LGPL source
#   3. build-d3d9.sh      DXVK d3d9, Vulkan loader, KosmicKrisp (D3D9 → Metal)
#   4. package-engine.sh  stage, relink, sign, prefix template, tarball
#   5. smoke/smoke-test.sh  DXMT, wined3d and DXVK (32/64-bit) and HTTPS, headless
#   6. public repo        PUBLIC_PATHS of this commit, committed and tagged vX.Y.Z-engine
#   7. source archive     meridian-engine-vX.Y.Z-engine-source.zip: that tag, and the
#                         upstream source of the LGPL and GPL components and of
#                         what DepotDownloader bundles (make_source_zip)
#   8. gh release create  from that tag, both files attached, not marked Latest
#
# Steps 1 to 5 build a commit, never the working tree, which must be clean
# (see Build). Uploading also needs a clone of $ENGINE_REPO at
# $PUBLIC_CHECKOUT (made on first use). PUBLIC_PATHS there mirror this
# repository: a file under them that this repository doesn't track is
# deleted by the next publish, so license files for those folders are
# committed here too.
#
# Prerequisites: Xcode command line tools, and
#   brew install meson ninja cmake bison flex autoconf automake libtool mingw-w64 coreutils gh dotnet pkgconf \
#                glslang llvm libclc spirv-llvm-translator spirv-tools

source "$(dirname "$0")/env.sh"

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-engine$ ]] || die "usage: publish-engine.sh vX.Y.Z-engine [--no-upload]"
UPLOAD=1; [ "${2:-}" = "--no-upload" ] && UPLOAD=0
HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$BUILD_ROOT/meridian-engine-arm64.tar.gz"
SOURCE_ZIP="$BUILD_ROOT/$(source_zip_name "$TAG")"
: "${PUBLIC_CHECKOUT:=$BUILD_ROOT/public-repo}"

# What the public repo carries of this one: the engine's build scripts and
# patches, and the helpers package-engine.sh builds from source that are
# published (DepotDownloader's patch, the CoreMessaging stand-in).
PUBLIC_PATHS=(
    Scripts/engine
    Scripts/depotdownloader
    Scripts/build-depotdownloader.sh
    Scripts/build-coremessaging.sh
    Scripts/coremessaging
)

case "$SOURCE_ZIP" in
    *.tar.gz|*.tar.xz) die "$SOURCE_ZIP would be installed as the engine: the source archive is a .zip" ;;
esac

# MARK: - Preflight

# Everything that can refuse the upload is checked before hours of building.
preflight() {
    command -v gh >/dev/null || die "brew install gh && gh auth login"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated: gh auth login"

    # Until the repo swap, aftrnd/meridian names the app repository (GitHub
    # ignores case; its full_name is aftrnd/Meridian), which then goes
    # private: an engine published there would be out of every app's reach.
    local repo
    repo="$(gh api "repos/$ENGINE_REPO" --jq '"\(.full_name) \(.visibility)"')" \
        || die "can't read $ENGINE_REPO"
    [ "$repo" = "$ENGINE_REPO public" ] || die "$ENGINE_REPO is \"$repo\", not the public engine repository"
    ! gh release view "$TAG" --repo "$ENGINE_REPO" >/dev/null 2>&1 \
        || die "$TAG already exists: engine releases are permanent"

    if [ ! -d "$PUBLIC_CHECKOUT/.git" ]; then
        mkdir -p "$(dirname "$PUBLIC_CHECKOUT")"
        gh repo clone "$ENGINE_REPO" "$PUBLIC_CHECKOUT" -- -q
        # Commits in a public repo show their email: the account's noreply one.
        git -C "$PUBLIC_CHECKOUT" config user.email \
            "$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
    fi
    local pub="$PUBLIC_CHECKOUT" url root
    url="$(git -C "$pub" remote get-url origin)"
    case "$url" in
        *github.com[:/]"$ENGINE_REPO" | *github.com[:/]"$ENGINE_REPO".git) ;;
        *) die "$pub pushes to $url, not $ENGINE_REPO" ;;
    esac
    # A clone made before the swap holds the app's history; pushed now it
    # would publish it.
    for root in $(git -C "$pub" rev-list --max-parents=0 HEAD); do
        ! git -C "$ROOT" cat-file -e "$root^{commit}" 2>/dev/null \
            || die "$pub shares history with $ROOT: clone $ENGINE_REPO again"
    done
    case "$(git -C "$pub" config user.email)" in
        *@users.noreply.github.com) ;;
        *) die "$pub commits as $(git -C "$pub" config user.email): set user.email to the GitHub noreply address" ;;
    esac
    [ -z "$(git -C "$pub" status --porcelain)" ] || die "uncommitted changes in $pub"
}

# MARK: - Build

# An engine is built from a commit and nothing else. The working tree must be
# clean, so the commit is what you see, and the build runs the commit's
# Scripts/, exported into $SNAPSHOT with git archive, so nothing else in the
# tree (an ignored file, an edit saved during hours of building) reaches it.
#
# The three long builds keep their output between runs, and each output has
# a record, $WORK/stamps/<output>.inputs: the git object, at the commit that
# built it, of every path it is built from (a folder's object is its tree,
# which changes when any file in it is added, changed or removed):
#   deps  env.sh, build-deps.sh
#   wine  those, build-wine.sh, patches/wine
#   d3d9  those, build-d3d9.sh, patches/dxvk
# Wine and the D3D9 path build against the libraries in $DEPS, hence
# "those". An output is reused only when its record equals this commit's.
# Otherwise it is deleted with the sources its build changes in place, and
# built again from fresh ones:
#   deps  $DEPS, and $SRC and $WORK, which hold everything else
#   wine  $WORK/wine-install, and $SRC/wine, which build-wine.sh patches
#         (build-deps.sh unpacks it again)
#   d3d9  $WORK/d3d9-install, and build-d3d9.sh's git checkouts (it patches
#         DXVK's)
# Only this script writes a record, once the build has succeeded, and each
# build script deletes its own before it changes anything, so a build by
# hand, or one that failed, never passes for a commit's. A record says what
# an output was built from, not that it is unchanged since: a file edited in
# an output by hand still passes. Delete $WORK/stamps to build everything.
# $SRC, $WORK and $DEPS belong to the build: anything put in them by hand is
# deleted when the libraries' inputs change.
#
# package-engine.sh makes everything else in the engine again on every run,
# from the snapshot: DXMT, DepotDownloader, Meridian's helpers, the prefix
# template and the license texts. Downloads in $DL are named by version, and
# every URL and revision is in the scripts. Not recorded: the host's tools
# (Xcode's clang, Homebrew's mingw-w64, meson and LLVM, the dotnet SDK).
SNAPSHOT="$BUILD_ROOT/snapshot"
DEPS_INPUTS=(Scripts/engine/env.sh Scripts/engine/build-deps.sh)
WINE_INPUTS=("${DEPS_INPUTS[@]}" Scripts/engine/build-wine.sh Scripts/engine/patches/wine)
D3D9_INPUTS=("${DEPS_INPUTS[@]}" Scripts/engine/build-d3d9.sh Scripts/engine/patches/dxvk)

# The record of paths at $SOURCE_COMMIT, one "<git object> <path>" per line.
inputs() {
    local p id
    for p in "$@"; do
        id="$(git -C "$ROOT" rev-parse -q --verify "$SOURCE_COMMIT:$p")" || id=absent
        echo "$id $p"
    done
}

# built_from <output> <path>...: the output's record names these inputs.
built_from() {
    local record="$WORK/stamps/$1.inputs"; shift
    [ -f "$record" ] && [ "$(cat "$record")" = "$(inputs "$@")" ]
}

record() {
    local record="$WORK/stamps/$1.inputs"; shift
    mkdir -p "$WORK/stamps"
    inputs "$@" > "$record"
}

build_engine() {
    local e="$SNAPSHOT/Scripts/engine"
    if built_from deps "${DEPS_INPUTS[@]}"; then
        say "Libraries: built from these inputs already"
    else
        say "Libraries: new inputs, so everything is built again"
        rm -rf "$SRC" "$WORK" "$DEPS"
    fi
    if built_from wine "${WINE_INPUTS[@]}" && [ -x "$WORK/wine-install/bin/wine" ]; then
        say "Wine: built from these inputs already"
    else
        rm -rf "$WORK/wine-install" "$SRC/wine"
    fi
    if built_from d3d9 "${D3D9_INPUTS[@]}" && [ -f "$WORK/d3d9-install/versions.txt" ]; then
        say "D3D9 path: built from these inputs already"
    else
        rm -rf "$WORK/d3d9-install" "$SRC/dxvk-git" "$SRC/Vulkan-Loader" "$SRC/mesa"
    fi

    bash "$e/build-deps.sh"
    record deps "${DEPS_INPUTS[@]}"
    [ -x "$WORK/wine-install/bin/wine" ] || bash "$e/build-wine.sh"
    record wine "${WINE_INPUTS[@]}"
    [ -f "$WORK/d3d9-install/versions.txt" ] || bash "$e/build-d3d9.sh"
    record d3d9 "${D3D9_INPUTS[@]}"
    bash "$e/package-engine.sh" "$TAG"
    bash "$e/smoke/smoke-test.sh"
}

# MARK: - Public repo

# This commit's PUBLIC_PATHS, committed and tagged in the public checkout.
# Idempotent: a rerun after a failed upload finds the same commit and tag.
sync_public_repo() {
    local pub="$PUBLIC_CHECKOUT" p
    say "Syncing ${PUBLIC_PATHS[*]} into $ENGINE_REPO"
    git -C "$pub" switch -q main
    git -C "$pub" pull -q --ff-only
    for p in "${PUBLIC_PATHS[@]}"; do
        rm -rf "${pub:?}/$p"
    done
    git -C "$ROOT" archive --format=tar "$SOURCE_COMMIT" -- "${PUBLIC_PATHS[@]}" | tar -x -C "$pub"
    git -C "$pub" add -A -- "${PUBLIC_PATHS[@]}"
    ! git -C "$pub" grep --cached -qF "$HOME" -- "${PUBLIC_PATHS[@]}" \
        || die "the public files name $HOME"
    if ! git -C "$pub" diff --cached --quiet; then
        git -C "$pub" diff --cached --stat | tail -1
        git -C "$pub" commit -q -m "Engine $TAG"
    fi
    if git -C "$pub" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        [ "$(git -C "$pub" rev-parse "$TAG^{commit}")" = "$(git -C "$pub" rev-parse HEAD)" ] \
            || die "$TAG already tags another commit in $pub"
    else
        git -C "$pub" tag -a "$TAG" -m "Meridian engine $TAG"
    fi
}

# MARK: - Source archive

# An upstream archive in $DL, fetched if the build didn't leave it there.
upstream() {
    local url="$1" name="${2:-${1##*/}}"
    if [ ! -f "$DL/$name" ]; then
        curl -fsSL -o "$DL/$name.part" "$url" || die "download failed: $url"
        mv "$DL/$name.part" "$DL/$name"
    fi
    echo "$DL/$name"
}

# Wine's winecrt0, which DXMT's release build links statically into
# winemetal.dll: DXMT's CI builds against the prebuilt Wine of 3Shain's
# v8.16-3shain release (DXMT v0.80's .github/workflows/ci.yml, WINE_URL).
# LGPL-2.1, so its source goes in the zip. Change it with DXMT_VERSION
# (package-engine.sh) when a new DXMT's CI names another Wine.
DXMT_WINE_SOURCE_URL="https://github.com/3Shain/wine/archive/4dd8a2d6dca39a116d0911f247bbaf1ad5e29471.tar.gz"

# The source of the engine's LGPL and GPL parts, as built:
#   meridian/   the public repo at $TAG (scripts, Wine/DXVK/DepotDownloader patches)
#   upstream/   Wine and its libraries, nettle, GLib and the subprojects it
#               built, the Wine whose winecrt0 is in DXMT's winemetal.dll, and
#               every package built into the GPL DepotDownloader binary
#               (licenses/depotdownloader/NOTICES.txt names them)
# Not in it: the compiler runtimes linked into the Windows binaries (libgcc,
# the MinGW-w64 runtime), and the other permissive components, whose
# revisions licenses/README.txt gives.
make_source_zip() {
    local name dir url file sources line
    name="$(basename "$SOURCE_ZIP" .zip)"
    dir="$WORK/source-zip/$name"
    say "Assembling $(basename "$SOURCE_ZIP")"
    rm -rf "$WORK/source-zip"; mkdir -p "$dir/upstream"
    git -C "$PUBLIC_CHECKOUT" archive --format=tar --prefix=meridian/ "$TAG" | tar -x -C "$dir"
    cp "$STAGE/licenses/README.txt" "$dir/COMPONENTS.txt"

    sources="$dir/SOURCES.txt"
    printf '# file\tsha256\turl\n' > "$sources"
    for url in "$WINE_SOURCE_URL" "$NETTLE_URL" "$GLIB_URL"; do
        file="$(upstream "$url")"
        cp "$file" "$dir/upstream/"
        printf '%s\t%s\t%s\n' "${file##*/}" "$(shasum -a 256 "$file" | cut -d' ' -f1)" "$url" >> "$sources"
    done
    file="$(upstream "$DXMT_WINE_SOURCE_URL" "wine-3shain-$(basename "$DXMT_WINE_SOURCE_URL" .tar.gz | cut -c1-8).tar.gz")"
    cp "$file" "$dir/upstream/"
    printf '%s\t%s\t%s\n' "${file##*/}" "$(shasum -a 256 "$file" | cut -d' ' -f1)" "$DXMT_WINE_SOURCE_URL" >> "$sources"
    # GLib's fallback subprojects (proxy-libintl, libffi, PCRE2) as meson
    # fetched them into the source tree.
    tar -C "$(unpacked "$GLIB_URL")" --exclude .git -czf "$dir/upstream/glib-subprojects.tar.gz" subprojects
    printf '%s\t%s\t%s\n' glib-subprojects.tar.gz \
        "$(shasum -a 256 "$dir/upstream/glib-subprojects.tar.gz" | cut -d' ' -f1)" "fetched by meson from GLib's .wrap files" >> "$sources"

    # Every package the restore resolved is built into the single-file
    # DepotDownloader (GPL-2.0), so each one's source goes in, once per
    # archive (the .NET packs share theirs). A GPL or LGPL package must have
    # an archive; any other without one is listed with where its source is.
    while IFS=$'\t' read -r -a line; do
        url="${line[3]:-}"
        if [[ "$url" != https://*.tar.gz ]]; then
            [[ "${line[2]:-}" != *GPL* ]] || die "no source archive for ${line[0]} (${line[2]}): $url"
            printf '%s\t%s\t%s\n' "${line[0]}-${line[1]%% *}" "not included" "${url:-unknown}" >> "$sources"
            continue
        fi
        grep -qF "$url" "$sources" && continue
        file="$(upstream "$url" "${line[0]}-${line[1]%% *}.tar.gz")"
        cp "$file" "$dir/upstream/"
        printf '%s\t%s\t%s\n' "${file##*/}" "$(shasum -a 256 "$file" | cut -d' ' -f1)" "$url" >> "$sources"
    done < <(grep -v '^#' "$STAGE/licenses/depotdownloader/NOTICES.txt")

    cat > "$dir/README.txt" <<EOF
Meridian engine $TAG: corresponding source

meridian/        Meridian's build scripts and patches, tagged $TAG in
                 https://github.com/${ENGINE_REPO}
upstream/        the source of the engine's LGPL and GPL components and of
                 every package built into DepotDownloader, as the build
                 fetched it (SOURCES.txt: SHA-256 and URL). Not here: the
                 compiler runtimes in the Windows binaries (gcc.gnu.org,
                 mingw-w64.org)
COMPONENTS.txt   the engine's main components and licenses, with the
                 revisions of the permissive ones (its licenses/README.txt).
                 THIRD-PARTY-NOTICES.md in meridian/ is the full list

Wine and its libraries build with meridian/Scripts/engine/build-deps.sh and
build-wine.sh, DepotDownloader with meridian/Scripts/build-depotdownloader.sh.
Each script's header lists what it needs.
EOF
    rm -f "$SOURCE_ZIP"
    (cd "$WORK/source-zip" && zip -qrX "$SOURCE_ZIP" "$name")
    du -sh "$SOURCE_ZIP"
}

# MARK: - Main

ROOT="$(git -C "$HERE" rev-parse --show-toplevel)" \
    || die "an engine is built from a commit: run publish-engine.sh in a git checkout"
[ -z "$(git -C "$ROOT" status --porcelain)" ] \
    || die "uncommitted changes in $ROOT: an engine is built from a commit only"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

[ "$UPLOAD" -eq 0 ] || preflight

rm -rf "$SNAPSHOT"; mkdir -p "$SNAPSHOT"
git -C "$ROOT" archive --format=tar "$SOURCE_COMMIT" -- Scripts | tar -x -C "$SNAPSHOT"
build_engine

[ "$UPLOAD" -eq 1 ] || { say "Built and smoke-tested $ARCHIVE from ${SOURCE_COMMIT:0:12} (not uploaded)"; exit 0; }

sync_public_repo
make_source_zip

say "Publishing $TAG to $ENGINE_REPO"
git -C "$PUBLIC_CHECKOUT" push -q origin main "refs/tags/$TAG"
# --verify-tag: the release is made from the tag just pushed, never one gh
# would create from the default branch. --latest=false: GitHub's "Latest"
# badge (and /releases/latest) belongs to the app's DMG release, not the
# engine the app downloads by itself.
gh release create "$TAG" --repo "$ENGINE_REPO" --verify-tag --latest=false --title "Engine $TAG" \
    "$ARCHIVE" "$SOURCE_ZIP" --notes "$(cat <<EOF
Meridian engine, built from source by Scripts/engine/.

- Wine $(cat "$SRC/wine/VERSION" | sed 's/Wine version //') from its published ${WINE_SOURCE_VERSION} source (LGPL-2.1) plus the Meridian patches
- DXMT $(sed 's/DXMT //' "$STAGE/wine/meridian-dxmt-version.txt") (D3D10/11 → Metal), selected per launch via WINEDLLPATH
- DXVK d3d9, the Khronos Vulkan loader and Mesa KosmicKrisp (D3D9 → Metal on macOS 26, for games that opt in): $(cat "$STAGE/wine/meridian-d3d9-version.txt")
- MoltenVK 1.4.2, GnuTLS, GStreamer (VideoToolbox decode)
- x86_64 under Rosetta 2, WoW64 for 32-bit games, 32-bit Wine modules built with SSE math

Not included: Apple D3DMetal, any closed-source component, the gbe_fork Steamworks emulator, Valve binaries.
License texts are in licenses/ inside the archive. $(basename "$SOURCE_ZIP") holds the complete source of its LGPL and GPL parts; the build scripts and patches are at https://github.com/${ENGINE_REPO}/tree/$TAG/Scripts/engine.
EOF
)"
say "Published $TAG"
