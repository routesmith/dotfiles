#!/usr/bin/env bash

set -euo pipefail

TOOL="gh"
OWNER_REPO="cli/cli"
API_URL="https://api.github.com/repos/${OWNER_REPO}/releases/latest"
SRC_ROOT="${SRC_ROOT:-$HOME/src}"
DOWNLOAD_ROOT="${DOWNLOAD_ROOT:-$SRC_ROOT/precompiled_binaries/$TOOL}"
EXTRACT_ROOT="$DOWNLOAD_ROOT/extracted"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_TARGET="$INSTALL_DIR/$TOOL"
VERSION_FILE="$INSTALL_DIR/.${TOOL}.version"
PREV_VERSION_FILE="$INSTALL_DIR/.${TOOL}.prev-version"

usage() {
    cat <<EOF
Usage:
  update_gh_compiled_binary.sh            Report and install latest GitHub CLI if needed
  update_gh_compiled_binary.sh --check    Report current/candidate versions only
  update_gh_compiled_binary.sh --rollback Roll back to the previously installed version
EOF
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd" >&2
        exit 1
    fi
}

for cmd in curl python3 tar sha256sum awk install uname grep; do
    require_cmd "$cmd"
done

case "$(uname -s)" in
    Linux) ;;
    *)
        echo "This updater is for WSL/Linux. Detected: $(uname -s)" >&2
        exit 1
        ;;
esac

if [[ -r /proc/sys/kernel/osrelease ]] && ! grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
    echo "Warning: This does not look like a WSL kernel; continuing because this is still Linux."
fi

case "$(uname -m)" in
    x86_64|amd64)
        GH_ARCH="amd64"
        ;;
    aarch64|arm64)
        GH_ARCH="arm64"
        ;;
    *)
        echo "Unsupported architecture for GitHub CLI Linux tarball: $(uname -m)" >&2
        exit 1
        ;;
esac

mkdir -p "$DOWNLOAD_ROOT" "$EXTRACT_ROOT" "$INSTALL_DIR"

fetch_latest_release() {
    curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$API_URL"
}

fetch_release_by_tag() {
    local tag="$1"
    curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/${OWNER_REPO}/releases/tags/${tag}"
}

select_release_assets() {
    local release_json_file="$1"

    GH_ARCH="$GH_ARCH" python3 - "$release_json_file" <<'PY'
import json
import os
import re
import sys

arch = os.environ["GH_ARCH"]
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

tag = data.get("tag_name", "")
version = tag.removeprefix("v")
assets = data.get("assets", [])

if not tag or not version:
    raise SystemExit("release JSON did not include tag_name")

tarball_re = re.compile(rf"^gh_{re.escape(version)}_linux_{re.escape(arch)}\.tar\.gz$")
checksums_re = re.compile(rf"^gh_{re.escape(version)}_checksums\.txt$")

def find_asset(pattern):
    for asset in assets:
        name = asset.get("name", "")
        url = asset.get("browser_download_url", "")
        if pattern.match(name) and url:
            return name, url
    return None

tarball = find_asset(tarball_re)
checksums = find_asset(checksums_re)

if not tarball:
    available = "\n".join(sorted(a.get("name", "") for a in assets))
    raise SystemExit(
        f"could not find Linux {arch} gh tarball for {tag}\n"
        f"looked for: gh_{version}_linux_{arch}.tar.gz\n"
        f"available assets:\n{available}"
    )

if not checksums:
    available = "\n".join(sorted(a.get("name", "") for a in assets))
    raise SystemExit(
        f"could not find checksums file for {tag}\n"
        f"looked for: gh_{version}_checksums.txt\n"
        f"available assets:\n{available}"
    )

print(tag, version, tarball[0], tarball[1], checksums[0], checksums[1], sep="\t")
PY
}

download_file() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.tmp"

    echo "Downloading $(basename "$dest")"
    curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
    mv "$tmp" "$dest"
}

verify_checksum() {
    local tarball="$1"
    local checksums="$2"
    local asset_name
    local expected

    asset_name="$(basename "$tarball")"
    expected="$(awk -v f="$asset_name" '$2 == f {print $1}' "$checksums")"

    if [[ -z "$expected" ]]; then
        echo "No checksum entry found for $asset_name in $checksums" >&2
        return 1
    fi

    printf '%s  %s\n' "$expected" "$tarball" | sha256sum -c - >/dev/null
}

current_installed_version() {
    if [[ -x "$INSTALL_TARGET" ]]; then
        "$INSTALL_TARGET" --version 2>/dev/null | awk 'NR == 1 {print $3}'
    elif command -v gh >/dev/null 2>&1; then
        gh --version 2>/dev/null | awk 'NR == 1 {print $3}'
    fi
}

report_update() {
    local current="$1"
    local candidate="$2"
    local tag="$3"

    echo "Current installed GitHub CLI: ${current:-not found}"
    echo "Candidate GitHub CLI release: $tag"

    if [[ "$current" == "$candidate" ]]; then
        echo "No update selected: installed gh already matches $candidate"
        return 1
    fi

    echo "Update selected: ${current:-not found} -> $candidate"
    return 0
}

save_prev_state() {
    local version
    version="$(current_installed_version || true)"
    if [[ -n "$version" ]]; then
        printf '%s\n' "$version" > "$PREV_VERSION_FILE"
    fi
}

install_gh_binary() {
    local version="$1"
    local tarball="$2"
    local extract_dir="$EXTRACT_ROOT/$version"
    local extracted_binary

    echo "Extracting $tarball"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"

    extracted_binary="$(find "$extract_dir" -type f -path '*/bin/gh' -print -quit)"

    if [[ -z "$extracted_binary" ]]; then
        echo "Could not find extracted gh binary under $extract_dir" >&2
        exit 1
    fi

    echo "Installing gh $version to $INSTALL_TARGET"
    install -m 0755 "$extracted_binary" "$INSTALL_TARGET"
    printf '%s\n' "$version" > "$VERSION_FILE"
}

rollback() {
    if [[ ! -r "$PREV_VERSION_FILE" ]]; then
        echo "No rollback state found at $PREV_VERSION_FILE" >&2
        echo "No previous version was saved; cannot rollback." >&2
        exit 1
    fi

    local prev_version
    prev_version="$(cat "$PREV_VERSION_FILE")"

    if [[ -z "$prev_version" ]]; then
        echo "Rollback state file $PREV_VERSION_FILE is empty." >&2
        exit 1
    fi

    echo "Rolling back GitHub CLI to version $prev_version"

    local release_json="$DOWNLOAD_ROOT/rollback-release.json"
    echo "Fetching release metadata for v${prev_version}..."
    fetch_release_by_tag "v${prev_version}" > "${release_json}.tmp"
    mv "${release_json}.tmp" "$release_json"

    IFS=$'\t' read -r TAG VERSION ASSET_NAME ASSET_URL CHECKSUM_NAME CHECKSUM_URL \
        < <(select_release_assets "$release_json")

    local TARBALL="$DOWNLOAD_ROOT/$ASSET_NAME"
    local CHECKSUMS="$DOWNLOAD_ROOT/$CHECKSUM_NAME"

    if [[ ! -f "$CHECKSUMS" ]]; then
        download_file "$CHECKSUM_URL" "$CHECKSUMS"
    fi

    if [[ ! -f "$TARBALL" ]]; then
        download_file "$ASSET_URL" "$TARBALL"
    fi

    if ! verify_checksum "$TARBALL" "$CHECKSUMS"; then
        echo "Existing tarball failed checksum; redownloading."
        rm -f "$TARBALL"
        download_file "$ASSET_URL" "$TARBALL"
        verify_checksum "$TARBALL" "$CHECKSUMS"
    fi

    echo "Checksum verified for $ASSET_NAME"
    install_gh_binary "$VERSION" "$TARBALL"

    echo "Rollback complete: $($INSTALL_TARGET --version | awk 'NR == 1 {print $3}')"
    echo "Rolled back to: v$prev_version"
}

main() {
    case "${1:-}" in
    -h | --help)
        usage
        ;;
    --rollback)
        rollback
        ;;
    --check | "")
        RELEASE_JSON="$DOWNLOAD_ROOT/latest-release.json"
        echo "Fetching latest GitHub CLI release metadata"
        fetch_latest_release > "${RELEASE_JSON}.tmp"
        mv "${RELEASE_JSON}.tmp" "$RELEASE_JSON"

        IFS=$'\t' read -r TAG VERSION ASSET_NAME ASSET_URL CHECKSUM_NAME CHECKSUM_URL \
            < <(select_release_assets "$RELEASE_JSON")

        if ! report_update "$(current_installed_version || true)" "$VERSION" "$TAG"; then
            [[ "${1:-}" == "--check" ]] && exit 0
            exit 0
        fi

        [[ "${1:-}" == "--check" ]] && exit 0

        save_prev_state

        TARBALL="$DOWNLOAD_ROOT/$ASSET_NAME"
        CHECKSUMS="$DOWNLOAD_ROOT/$CHECKSUM_NAME"

        echo "Selected asset: $ASSET_NAME"
        echo "Archive directory: $DOWNLOAD_ROOT"

        if [[ ! -f "$CHECKSUMS" ]]; then
            download_file "$CHECKSUM_URL" "$CHECKSUMS"
        else
            echo "Reusing existing checksums: $CHECKSUMS"
        fi

        if [[ ! -f "$TARBALL" ]]; then
            download_file "$ASSET_URL" "$TARBALL"
        else
            echo "Reusing existing tarball: $TARBALL"
        fi

        if ! verify_checksum "$TARBALL" "$CHECKSUMS"; then
            echo "Existing tarball failed checksum; redownloading."
            rm -f "$TARBALL"
            download_file "$ASSET_URL" "$TARBALL"
            verify_checksum "$TARBALL" "$CHECKSUMS"
        fi

        echo "Checksum verified for $ASSET_NAME"
        install_gh_binary "$VERSION" "$TARBALL"

        RESOLVED_GH="$(command -v gh || true)"
        if [[ -n "$RESOLVED_GH" && "$RESOLVED_GH" != "$INSTALL_TARGET" ]]; then
            echo "Warning: command -v gh resolves to $RESOLVED_GH"
            echo "   Make sure $INSTALL_DIR appears before any system gh location in PATH."
        fi

        echo "Installed version: $($INSTALL_TARGET --version | awk 'NR == 1 {print $3}')"
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
}

main "$@"
