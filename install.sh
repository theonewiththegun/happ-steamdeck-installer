#!/usr/bin/env bash
#
# Happ Desktop Installer
# https://github.com/theonewiththegun/happ-steamdeck-installer (fork of DeadFlamingo/happ-steamdeck-installer)
#
# Supported systems:
#   - SteamOS / Steam Deck
#   - Bazzite, ChimeraOS, Nobara
#   - Arch Linux and other rolling distros
#   - Immutable / read-only root filesystems (no steamos-readonly disable)
#
# Installs Happ Desktop into a root-owned /var/lib/happ, because happd runs it
# as root; launcher and icons go to ~/.local. Needs sudo (run `passwd` first).

set -Eeuo pipefail

INSTALLER_VERSION="2.0.0"
HAPPD_SERVICE_PATH="/etc/systemd/system/happd.service"
UPSTREAM_REPO="Happ-proxy/happ-desktop"
LATEST_API="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"

PREFIX="${HOME}/.local"
BIN_DIR="${PREFIX}/bin"
APP_DIR="${PREFIX}/share/applications"
ICON_DIR="${PREFIX}/share/icons/hicolor/256x256/apps"
MARKER_FILE="${PREFIX}/share/happ-installer/installed.json"
HAPP_ROOT="/var/lib/happ"
HAPP_BIN="${HAPP_ROOT}/bin/Happ"
LEGACY_OPT_DIR="${PREFIX}/opt/happ"
REPO_RAW="https://raw.githubusercontent.com/theonewiththegun/happ-steamdeck-installer/main"

TMP_DIR=""
ROOT_TMP=""
STAGING_DIR=""

# --- output helpers ----------------------------------------------------------

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_GREEN='\033[0;32m'
  C_BLUE='\033[0;34m'
  C_YELLOW='\033[1;33m'
  C_RED='\033[0;31m'
  C_RESET='\033[0m'
else
  C_GREEN='' C_BLUE='' C_YELLOW='' C_RED='' C_RESET=''
fi

info()  { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}==>${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}warning:${C_RESET} $*" >&2; }
error() { echo -e "${C_RED}error:${C_RESET} $*" >&2; }

die() {
  error "$1"
  exit "${2:-1}"
}

# --- cleanup -----------------------------------------------------------------

cleanup() {
  local code=$?
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
  if [[ -n "${ROOT_TMP}" ]]; then
    sudo rm -rf "${ROOT_TMP}" 2>/dev/null || true
  fi
  return "${code}"
}

trap cleanup EXIT

# --- dependencies ------------------------------------------------------------

require_cmd() {
  local cmd=$1
  local hint=${2:-}
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    die "Required command not found: ${cmd}${hint:+ (${hint})}"
  fi
}

check_tar_zstd() {
  if tar --help 2>&1 | grep -q -- '--zstd'; then
    TAR_EXTRACT=(tar --zstd --no-same-owner -xf)
    return 0
  fi
  if command -v bsdtar >/dev/null 2>&1; then
    TAR_EXTRACT=(bsdtar --no-same-owner -xf)
    return 0
  fi
  die "Need GNU tar with zstd support or bsdtar to extract .pkg.tar.zst"
}

# --- architecture ------------------------------------------------------------

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64)
      echo "x64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      die "Unsupported CPU architecture: ${machine} (supported: x86_64, aarch64)"
      ;;
  esac
}

# --- GitHub API (jq or python3) ----------------------------------------------

fetch_latest_json() {
  local json
  json="$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: happ-steamdeck-installer/${INSTALLER_VERSION}" \
    "${LATEST_API}")" || die "Failed to fetch latest release from GitHub API"
  echo "${json}"
}

json_get_asset() {
  local json=$1
  local arch=$2
  local field=$3
  local pkg_name="Happ.linux.${arch}.pkg.tar.zst"

  if command -v jq >/dev/null 2>&1; then
    case "${field}" in
      url)
        echo "${json}" | jq -r --arg n "${pkg_name}" \
          '.assets[] | select(.name == $n) | .browser_download_url'
        ;;
      digest)
        echo "${json}" | jq -r --arg n "${pkg_name}" \
          '.assets[] | select(.name == $n) | .digest // empty'
        ;;
      version)
        echo "${json}" | jq -r '.tag_name'
        ;;
    esac
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    local py_tmp
    py_tmp="$(mktemp "${TMPDIR:-/tmp}/happ-json.XXXXXX")"
    printf '%s' "${json}" > "${py_tmp}"
    python3 - "${py_tmp}" "${pkg_name}" "${field}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
name = sys.argv[2]
field = sys.argv[3]
asset = next((a for a in data.get("assets", []) if a.get("name") == name), None)
if asset is None:
    sys.exit(1)
if field == "url":
    print(asset["browser_download_url"])
elif field == "digest":
    print(asset.get("digest") or "")
elif field == "version":
    print(data["tag_name"])
PY
    local py_status=$?
    rm -f "${py_tmp}"
    return "${py_status}"
  fi

  die "Install jq or python3 to read GitHub release metadata"
}

# --- install steps -----------------------------------------------------------

require_sudo() {
  require_cmd sudo
  info "Asking for sudo (Happ is installed root-owned, happd runs as root)..."
  sudo -v || die "sudo failed. On Steam Deck set a password first with: passwd"
}

# Verify and unpack as root in a root-only directory, so nothing between the
# hash check and the install is writable by the desktop user.
stage_package_as_root() {
  local archive=$1 expected=$2 actual
  ROOT_TMP="$(sudo mktemp -d /var/tmp/happ-install.XXXXXX)"
  sudo install -m600 "${archive}" "${ROOT_TMP}/pkg.tar.zst"
  actual="$(sudo sha256sum "${ROOT_TMP}/pkg.tar.zst" | cut -d' ' -f1)"
  [[ "${actual}" == "${expected}" ]] \
    || die "SHA-256 mismatch: expected ${expected}, got ${actual}"
  ok "SHA-256 verified (${actual})"
  STAGING_DIR="${ROOT_TMP}/staging"
  sudo mkdir -m755 "${STAGING_DIR}"
  sudo "${TAR_EXTRACT[@]}" "${ROOT_TMP}/pkg.tar.zst" -C "${STAGING_DIR}"
  sudo chmod 755 "${ROOT_TMP}"
}

install_happ_payload() {
  local opt_src="${STAGING_DIR}/opt/happ"

  sudo test -f "${opt_src}/bin/Happ" || die "Happ binary not found in package: opt/happ/bin/Happ"
  sudo test -f "${opt_src}/bin/happd" || die "happd not found in package: opt/happ/bin/happd"

  sudo chown -R root:root "${opt_src}"
  sudo chmod -R go-w "${opt_src}"
  sudo chmod 755 "${opt_src}"

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop happd.service 2>/dev/null || true
  fi
  sudo rm -rf "${HAPP_ROOT}.old"
  if sudo test -d "${HAPP_ROOT}"; then
    sudo mv "${HAPP_ROOT}" "${HAPP_ROOT}.old"
  fi
  sudo mv "${opt_src}" "${HAPP_ROOT}"
  sudo rm -rf "${HAPP_ROOT}.old"

  if [[ -d "${LEGACY_OPT_DIR}" ]]; then
    info "Removing old user-writable install at ${LEGACY_OPT_DIR}"
    rm -rf "${LEGACY_OPT_DIR}"
    rmdir "${PREFIX}/opt" 2>/dev/null || true
  fi

  cat > "${BIN_DIR}/happ" <<EOF
#!/usr/bin/env bash
if [[ ! -x "${HAPP_BIN}" ]]; then
  echo "Happ is missing from ${HAPP_ROOT}; re-run the installer:" >&2
  echo "  curl -fsSL ${REPO_RAW}/install.sh | bash" >&2
  exit 1
fi
exec "${HAPP_BIN}" "\$@"
EOF
  chmod +x "${BIN_DIR}/happ"
}

write_happd_unit() {
  local dest=$1 upstream="${STAGING_DIR}/etc/systemd/system/happd.service"
  if sudo test -f "${upstream}"; then
    sudo sed "s|^ExecStart=.*|ExecStart=${HAPP_ROOT}/bin/happd|" "${upstream}" > "${dest}"
    return 0
  fi
  warn "happd.service not found in package; writing a minimal unit"
  cat > "${dest}" <<EOF
[Unit]
Description=Happ Process Control Daemon
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${HAPP_ROOT}/bin/happd
Restart=always
RestartSec=5s
TimeoutStopSec=10s
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF
}

install_happd_service() {
  local tmp_service

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; skipping happd (TUN mode will not work)"
    return 0
  fi

  tmp_service="$(mktemp "${TMP_DIR}/happd-service.XXXXXX")"
  write_happd_unit "${tmp_service}"
  sudo install -o root -g root -Dm644 "${tmp_service}" "${HAPPD_SERVICE_PATH}" \
    || die "Failed to install ${HAPPD_SERVICE_PATH}"

  sudo systemctl daemon-reload || die "systemctl daemon-reload failed"
  sudo systemctl enable happd.service || warn "systemctl enable happd.service failed"
  if sudo systemctl restart happd.service; then
    ok "happd.service is running (TUN / VPN mode)"
  else
    warn "happd.service installed but did not start - run: sudo systemctl status happd"
  fi
}

install_icon() {
  local src=$1
  local size dir
  for size in 48 128 256; do
    dir="${PREFIX}/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "${dir}"
    install -Dm644 "${src}" "${dir}/happ.png"
  done

  if command -v xdg-icon-resource >/dev/null 2>&1; then
    xdg-icon-resource install --novendor --size 256 "${ICON_DIR}/happ.png" happ 2>/dev/null || true
    xdg-icon-resource forceupdate 2>/dev/null || true
  fi
}

find_desktop_in_staging() {
  local candidate
  for candidate in \
    "${STAGING_DIR}/usr/share/applications/Happ.desktop" \
    "${STAGING_DIR}/usr/share/applications/happ.desktop"; do
    if [[ -f "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  find "${STAGING_DIR}" -type f -path '*/share/applications/*.desktop' \
    \( -iname 'happ.desktop' -o -iname 'Happ.desktop' \) 2>/dev/null | head -n1
}

find_icon_in_staging() {
  local candidate="${STAGING_DIR}/usr/share/icons/hicolor/256x256/apps/happ.png"
  if [[ -f "${candidate}" ]]; then
    echo "${candidate}"
    return 0
  fi
  find "${STAGING_DIR}" -type f -path '*/share/icons/*/apps/happ.png' 2>/dev/null | head -n1
}

write_desktop_entry_fallback() {
  local dest="${APP_DIR}/happ.desktop"
  local exec_path="${BIN_DIR}/happ"

  mkdir -p "${APP_DIR}"
  cat > "${dest}" <<EOF
[Desktop Entry]
Type=Application
Name=Happ
Exec=${exec_path} %f
Icon=happ
Categories=Network;Utility;
Terminal=false
EOF

  if command -v xdg-desktop-menu >/dev/null 2>&1; then
    xdg-desktop-menu install --novendor "${dest}" 2>/dev/null || true
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APP_DIR}" 2>/dev/null || true
  fi
}

install_desktop_entry() {
  local src=$1
  local dest="${APP_DIR}/happ.desktop"
  local exec_path="${BIN_DIR}/happ"

  mkdir -p "${APP_DIR}"
  sed \
    -e "s|^Exec=.*|Exec=${exec_path}|" \
    -e "s|^Icon=.*|Icon=happ|" \
    "${src}" > "${dest}"

  if command -v xdg-desktop-menu >/dev/null 2>&1; then
    xdg-desktop-menu install --novendor "${dest}" 2>/dev/null || true
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APP_DIR}" 2>/dev/null || true
  fi
}

write_marker() {
  local version=$1
  mkdir -p "$(dirname "${MARKER_FILE}")"
  cat > "${MARKER_FILE}" <<EOF
{
  "installer_version": "${INSTALLER_VERSION}",
  "happ_version": "${version}",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "prefix": "${PREFIX}",
  "happ_root": "${HAPP_ROOT}"
}
EOF
}

main() {
  clear 2>/dev/null || true
  echo -e "${C_BLUE}=== Happ Desktop Installer v${INSTALLER_VERSION} ===${C_RESET}"
  echo

  require_cmd curl
  check_tar_zstd

  local arch pkg_url digest version archive_name archive_path
  arch="$(detect_arch)"
  archive_name="Happ.linux.${arch}.pkg.tar.zst"

  info "Detecting latest Happ release (${arch})..."
  local latest_json
  latest_json="$(fetch_latest_json)"

  pkg_url="$(json_get_asset "${latest_json}" "${arch}" url)" || true
  digest="$(json_get_asset "${latest_json}" "${arch}" digest)" || true
  version="$(json_get_asset "${latest_json}" "${arch}" version)" || true

  if [[ -z "${pkg_url}" || "${pkg_url}" == "null" ]]; then
    die "Package not found in latest release: ${archive_name}"
  fi
  [[ "${digest}" == sha256:* ]] \
    || die "GitHub returned no SHA-256 digest for ${archive_name}; refusing to install unverified"

  ok "Latest version: ${version}"

  mkdir -p "${HOME}/.cache"
  TMP_DIR="$(mktemp -d "${HOME}/.cache/happ-installer.XXXXXX")"
  archive_path="${TMP_DIR}/${archive_name}"
  mkdir -p "${BIN_DIR}" "${APP_DIR}"

  info "[1/5] Downloading ${archive_name}..."
  curl -fsSL --progress-bar -o "${archive_path}" "${pkg_url}" \
    || die "Download failed"

  require_sudo

  info "[2/5] Verifying and extracting package..."
  stage_package_as_root "${archive_path}" "${digest#sha256:}"

  local desktop_src icon_src

  desktop_src="$(find_desktop_in_staging || true)"
  icon_src="$(find_icon_in_staging || true)"

  info "[3/5] Installing to ${HAPP_ROOT}..."
  install_happ_payload

  info "[4/5] Configuring system daemon..."
  install_happd_service

  if [[ -n "${icon_src}" && -f "${icon_src}" ]]; then
    install_icon "${icon_src}"
  else
    warn "Icon not found in package; launcher may use a generic icon"
  fi

  if [[ -n "${desktop_src}" && -f "${desktop_src}" ]]; then
    install_desktop_entry "${desktop_src}"
  else
    warn "Desktop entry not found in package; creating a minimal launcher"
    write_desktop_entry_fallback
  fi

  write_marker "${version}"

  info "[5/5] Finalizing..."
  ok "Happ ${version} installed successfully"
  echo
  echo "Next steps:"
  echo "  1. Open the application menu and find Happ (often under Internet)."
  echo "  2. Right-click Happ -> Add to Steam."
  echo "  3. Launch Happ from Gaming Mode on Steam Deck."
  echo
  echo "App files: ${HAPP_ROOT} (root-owned)  |  TUN daemon: ${HAPPD_SERVICE_PATH}"
  echo "If a SteamOS update removes Happ, re-run this installer."
  echo
  echo "To remove: curl -fsSL ${REPO_RAW}/uninstall.sh | bash"
}

main "$@"
