#!/usr/bin/env bash
#
# build-depotdownloader.sh — build Meridian's patched DepotDownloader fork.
#
# Meridian installs owned games headlessly (no steam.exe) by driving a patched
# fork of SteamRE/DepotDownloader. The fork adds:
#   • -refreshtoken <jwt>  → token-only logon (consumes Meridian's OAuth token;
#                            interactive credential/QR/Steam-Guard auth removed)
#   • -json                → newline-delimited JSON progress on stdout
#   • SIGTERM/SIGINT        → deterministic exit 130 (resume-safe via
#                            .DepotDownloader/depot.config)
#
# Upstream: https://github.com/SteamRE/DepotDownloader @ b2b7e975 (v3.4.0, GPL-2.0)
# Patch:    Scripts/depotdownloader/meridian-task1.patch
#
# Output: a self-contained single-file osx-arm64 Mach-O binary. By default it is
# written into the live engine at:
#   ~/Library/Application Support/com.meridian.app/engine/tools/depotdownloader/DepotDownloader
# Pass an explicit output path as $1 to override (package-engine.sh stages it
# into the engine tarball this way).
#
# Pass a directory as $2 to also write the binary's license notices there
# (package-engine.sh puts them in the engine's licenses/depotdownloader/):
#   DepotDownloader-GPL-2.0.txt   the fork's license
#   NOTICES.txt                   the fork and every package its restore resolved
#                                 (NuGet packages, the .NET runtime and host packs),
#                                 one per line with license and source
#   <package>-<version>-<file>    each package's own license and notice files
#
# Requires: dotnet SDK 9+ (`brew install dotnet`), git.

set -euo pipefail

UPSTREAM_REPO="https://github.com/SteamRE/DepotDownloader.git"
UPSTREAM_COMMIT="b2b7e975adb8f09f0e2592484f06d28f6c8683ed"
RID="osx-arm64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${SCRIPT_DIR}/depotdownloader/meridian-task1.patch"

DEFAULT_OUT="${HOME}/Library/Application Support/com.meridian.app/engine/tools/depotdownloader/DepotDownloader"
OUT="${1:-${DEFAULT_OUT}}"
NOTICES="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

command -v dotnet >/dev/null 2>&1 || die "dotnet not found — run 'brew install dotnet' (SDK 9+)"
command -v git >/dev/null 2>&1 || die "git not found"
[ -f "${PATCH}" ] || die "patch not found at ${PATCH}"

WORK="$(mktemp -d /tmp/meridian-dd-build.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

echo "Building DepotDownloader fork (upstream ${UPSTREAM_COMMIT:0:12}, RID ${RID})..."
info "clone"
git clone --quiet "${UPSTREAM_REPO}" "${WORK}/src"
git -C "${WORK}/src" checkout --quiet "${UPSTREAM_COMMIT}"

info "apply Meridian patch"
git -C "${WORK}/src" apply "${PATCH}" || die "patch failed to apply (upstream may have moved — re-base the patch)"

# Upstream pins the SDK to 9.0.x via global.json with rollForward=latestMinor,
# so a machine that only has a newer major (e.g. 10.x) can't build it. This is a
# throwaway clone in /tmp, so relax the pin to latestMajor — the build works with
# any installed SDK >= 9 and the self-contained publish restores the correct
# net9.0 runtime pack regardless. (We never touch the repo's global.json.)
if [ -f "${WORK}/src/global.json" ]; then
    info "relax global.json SDK pin (rollForward=latestMajor) for this build"
    /usr/bin/python3 - "${WORK}/src/global.json" <<'PY' || true
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
    d.setdefault("sdk", {})["rollForward"] = "latestMajor"
    json.dump(d, open(p, "w"), indent=2)
except Exception as e:
    print("  (could not adjust global.json: %s)" % e)
PY
fi

info "dotnet publish (self-contained single-file)"
dotnet publish "${WORK}/src/DepotDownloader/DepotDownloader.csproj" \
    -c Release \
    -r "${RID}" \
    --self-contained true \
    -p:PublishSingleFile=true \
    -o "${WORK}/publish" \
    >/dev/null || die "dotnet publish failed"

[ -f "${WORK}/publish/DepotDownloader" ] || die "publish produced no DepotDownloader binary"

mkdir -p "$(dirname "${OUT}")"
cp "${WORK}/publish/DepotDownloader" "${OUT}"
chmod +x "${OUT}"
# Strip quarantine: macOS 26 blocks network access for quarantined binaries,
# and DepotDownloader needs the network.
xattr -rd com.apple.quarantine "${OUT}" 2>/dev/null || true

# MARK: - License notices

# The single-file binary carries packages from the restore that built it (the
# project's packages, and the .NET runtime and host packs a self-contained
# publish downloads). The notices list everything that restore resolved: a
# few build-only packages too, never a gap.
if [ -n "${NOTICES}" ]; then
    info "license notices"
    mkdir -p "${NOTICES}"
    cp "${WORK}/src/LICENSE" "${NOTICES}/DepotDownloader-GPL-2.0.txt"
    /usr/bin/python3 -I - "${WORK}/src/DepotDownloader/obj/project.assets.json" "${NOTICES}" \
        "DepotDownloader" "${UPSTREAM_COMMIT:0:12} + meridian-task1.patch" "GPL-2.0" \
        "${UPSTREAM_REPO%.git}/archive/${UPSTREAM_COMMIT}.tar.gz" <<'PY' || die "license notices failed"
import json, os, re, shutil, sys
import xml.etree.ElementTree as ET

assets_path, out, *fork = sys.argv[1:]
assets = json.load(open(assets_path))
roots = list(assets["packageFolders"])

packages = {}
for key, lib in assets["libraries"].items():
    if lib.get("type") == "package":
        name, version = key.split("/", 1)
        packages[(name, version)] = lib["path"]
for framework in assets["project"]["frameworks"].values():
    for dep in framework.get("downloadDependencies", []):
        version = dep["version"].strip("[]").split(",")[0].strip()
        packages[(dep["name"], version)] = "%s/%s" % (dep["name"].lower(), version)

NOTICE_FILE = re.compile(r"^(licen[cs]e|copying|notice|third-party-notices|3rd party)", re.I)

def folder(rel):
    for root in roots:
        d = os.path.join(root, rel)
        if os.path.isdir(d):
            return d
    sys.exit("package folder not found: " + rel)

def nuspec(d):
    meta = {}
    spec = next((f for f in os.listdir(d) if f.endswith(".nuspec")), None)
    if spec is None:
        return meta
    for el in ET.parse(os.path.join(d, spec)).getroot().iter():
        tag = el.tag.rsplit("}", 1)[-1]
        text = (el.text or "").strip()
        if tag == "license" and el.get("type") == "file":
            meta["license"], meta["file"] = "see " + text, text
        elif tag == "license":
            meta["license"] = text
        elif tag == "licenseUrl":
            meta.setdefault("license", text)
        elif tag == "projectUrl":
            meta["project"] = text
        elif tag == "repository":
            meta["repo"], meta["commit"] = el.get("url", ""), el.get("commit", "")
    return meta

lines = ["# component\tversion\tlicense\tsource", "\t".join(fork)]
for (name, version), rel in sorted(packages.items(), key=lambda p: p[0][0].lower()):
    d = folder(rel)
    meta = nuspec(d)
    repo = meta.get("repo", "").removesuffix(".git")
    if repo.startswith("https://github.com/") and meta.get("commit"):
        source = "%s/archive/%s.tar.gz" % (repo, meta["commit"])
    else:
        source = repo or meta.get("project") or "unknown"
    lines.append("\t".join([name, version, meta.get("license") or "unknown", source]))
    for f in sorted(os.listdir(d)):
        if (NOTICE_FILE.match(f) or f == meta.get("file")) and os.path.isfile(os.path.join(d, f)):
            shutil.copyfile(os.path.join(d, f), os.path.join(out, "%s-%s-%s" % (name, version, f)))

open(os.path.join(out, "NOTICES.txt"), "w").write("\n".join(lines) + "\n")
PY
fi

echo "✓ DepotDownloader → ${OUT} ($(stat -f%z "${OUT}") bytes)"
"${OUT}" 2>&1 | head -1 || true
