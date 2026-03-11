#!/usr/bin/env bash
#
# release-engine.sh — Package and upload the Wine+GPTK engine runtime.
#
# Usage:
#   bash Scripts/release-engine.sh [VERSION]
#
# Examples:
#   bash Scripts/release-engine.sh              # auto-increments patch (v1.0.1-engine)
#   bash Scripts/release-engine.sh v2.0.0       # explicit version
#
# Prerequisites:
#   - Wine Crossover installed via: brew tap gcenx/wine && brew install --cask wine-crossover
#   - gh CLI authenticated: gh auth status
#
# What it does:
#   1. Locates Wine Crossover app bundle
#   2. Copies wine/{bin,lib,share} into a staging directory
#   3. Verifies wine64 and wineserver are present
#   4. Creates a .tar.gz archive
#   5. Uploads it as a GitHub release to aftrnd/meridian
#
set -euo pipefail

REPO="aftrnd/meridian"
WINE_APP="/Applications/Wine Crossover.app"
WINE_RESOURCES="${WINE_APP}/Contents/Resources"
STAGING="/tmp/meridian-engine"
ARCHIVE="/tmp/meridian-engine-arm64.tar.gz"

# ---------- helpers ----------

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
die()    { red "ERROR: $*" >&2; exit 1; }

# ---------- preflight ----------

echo ""
green "=== Meridian Engine Release ==="
echo ""

command -v gh >/dev/null 2>&1 || die "gh CLI not found. Install: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated. Run: gh auth login"

[ -d "${WINE_APP}" ] || die "Wine Crossover not found at ${WINE_APP}. Install: brew tap gcenx/wine && brew install --cask wine-crossover"
[ -f "${WINE_RESOURCES}/wine/bin/wine64" ] || die "wine64 not found in ${WINE_APP}"
[ -f "${WINE_RESOURCES}/wine/bin/wineserver" ] || die "wineserver not found in ${WINE_APP}"

# ---------- version ----------

if [ -n "${1:-}" ]; then
    VERSION="$1"
else
    LATEST=$(gh release list --repo "${REPO}" --limit 50 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+-engine' \
        | sort -V | tail -1 || true)

    if [ -z "${LATEST}" ]; then
        VERSION="v1.0.0-engine"
    else
        BASE="${LATEST%-engine}"
        MAJOR=$(echo "${BASE}" | cut -d. -f1 | tr -d 'v')
        MINOR=$(echo "${BASE}" | cut -d. -f2)
        PATCH=$(echo "${BASE}" | cut -d. -f3)
        PATCH=$((PATCH + 1))
        VERSION="v${MAJOR}.${MINOR}.${PATCH}-engine"
    fi
    yellow "Auto-detected next version: ${VERSION}"
fi

# Ensure tag has -engine suffix
[[ "${VERSION}" == *-engine ]] || VERSION="${VERSION}-engine"
TAG="${VERSION}"

info "Version:  ${VERSION}"
info "Tag:      ${TAG}"
info "Repo:     ${REPO}"
echo ""

# ---------- detect Wine version ----------

WINE_VERSION=$("${WINE_RESOURCES}/wine/bin/wine64" --version 2>/dev/null || echo "unknown")
info "Wine version: ${WINE_VERSION}"

# ---------- stage ----------

yellow "Staging engine..."
rm -rf "${STAGING}" "${ARCHIVE}"
mkdir -p "${STAGING}/wine"
cp -R "${WINE_RESOURCES}/wine/"* "${STAGING}/wine/"

# Verify critical binaries
[ -x "${STAGING}/wine/bin/wine64" ]    || die "wine64 not executable in staging"
[ -x "${STAGING}/wine/bin/wineserver" ] || die "wineserver not executable in staging"
[ -x "${STAGING}/wine/bin/wineboot" ] 2>/dev/null || info "wineboot is a shell script (OK)"

FILE_COUNT=$(find "${STAGING}" -type f | wc -l | tr -d ' ')
STAGING_SIZE=$(du -sh "${STAGING}" | cut -f1)
info "Staged ${FILE_COUNT} files (${STAGING_SIZE})"

# ---------- archive ----------

yellow "Creating archive..."
cd /tmp && tar czf "${ARCHIVE}" -C "${STAGING}" .
ARCHIVE_SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
info "Archive: ${ARCHIVE} (${ARCHIVE_SIZE})"

# Verify tarball contents
TARBALL_CHECK=$(tar tzf "${ARCHIVE}" | grep -c "wine/bin/wine64" || true)
[ "${TARBALL_CHECK}" -ge 1 ] || die "Tarball does not contain wine/bin/wine64"

# ---------- upload ----------

yellow "Uploading release ${TAG} to ${REPO}..."

NOTES="Wine engine runtime for Meridian.

**Wine version:** ${WINE_VERSION}
**Architecture:** x86_64 (runs via Rosetta 2 on Apple Silicon)
**Archive size:** ${ARCHIVE_SIZE}
**Files:** ${FILE_COUNT}

**Contents:**
- \`wine/bin/wine64\` — Wine 64-bit binary
- \`wine/bin/wineserver\` — Wine server
- \`wine/lib/\` — MoltenVK, system libraries, Wine DLLs
- \`wine/share/wine/\` — Gecko, Mono, fonts, NLS files

**Install target:**
\`~/Library/Application Support/com.meridian.app/engine/\`"

gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "Wine+GPTK Engine ${VERSION}" \
    --notes "${NOTES}" \
    "${ARCHIVE}"

# ---------- cleanup ----------

rm -rf "${STAGING}" "${ARCHIVE}"

echo ""
green "Release ${TAG} published:"
gh release view "${TAG}" --repo "${REPO}" --json url -q '.url'
echo ""
green "Done."
