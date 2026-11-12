#!/usr/bin/env bash
#
# Happ Desktop uninstaller (/home/.happ, happd system service, ~/.local launcher)

set -Eeuo pipefail

INSTALLER_VERSION="2.1.0"
PREFIX="${HOME}/.local"
BIN_PATH="${PREFIX}/bin/happ"
DESKTOP_PATH="${PREFIX}/share/applications/happ.desktop"
MARKER_DIR="${PREFIX}/share/happ-installer"
HAPP_ROOT="/home/.happ"
OLD_VAR_ROOT="/var/lib/happ"
LEGACY_OPT_DIR="${PREFIX}/opt/happ"
HAPPD_SERVICE_PATH="/etc/systemd/system/happd.service"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_GREEN='\033[0;32m'
  C_BLUE='\033[0;34m'
  C_YELLOW='\033[1;33m'
  C_RESET='\033[0m'
else
  C_GREEN='' C_BLUE='' C_YELLOW='' C_RESET=''
fi

info()  { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}==>${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}warning:${C_RESET} $*" >&2; }

echo -e "${C_BLUE}=== Happ Desktop Uninstaller v${INSTALLER_VERSION} ===${C_RESET}"
echo

removed=0

remove_root_files() {
  if [[ ! -f "${HAPPD_SERVICE_PATH}" && ! -d "${HAPP_ROOT}" && ! -d "${OLD_VAR_ROOT}" ]]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    warn "Cannot remove ${HAPPD_SERVICE_PATH} automatically (need sudo and systemctl)"
    return 0
  fi

  info "Removing happd service and ${HAPP_ROOT} (sudo)..."
  if sudo -v; then
    sudo systemctl disable --now happd.service 2>/dev/null || true
    sudo rm -f "${HAPPD_SERVICE_PATH}"
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo rm -rf "${HAPP_ROOT}" "${HAPP_ROOT}.old" "${OLD_VAR_ROOT}" "${OLD_VAR_ROOT}.old" \
      /home/.happ-install.* /var/tmp/happ-install.*
    sudo rm -f /var/log/happd.log /var/log/happd.log.old
    removed=1
    info "Removed ${HAPPD_SERVICE_PATH} and ${HAPP_ROOT}"
  else
    warn "sudo failed - remove these manually:"
    echo "  sudo systemctl disable --now happd.service"
    echo "  sudo rm -f ${HAPPD_SERVICE_PATH} && sudo systemctl daemon-reload"
    echo "  sudo rm -rf ${HAPP_ROOT}"
  fi
}

remove_root_files

if [[ -f "${BIN_PATH}" || -L "${BIN_PATH}" ]]; then
  rm -f "${BIN_PATH}"
  removed=1
  info "Removed ${BIN_PATH}"
fi

if [[ -d "${LEGACY_OPT_DIR}" ]]; then
  rm -rf "${LEGACY_OPT_DIR}"
  removed=1
  info "Removed ${LEGACY_OPT_DIR}"
  rmdir "${PREFIX}/opt" 2>/dev/null || true
fi

if [[ -f "${DESKTOP_PATH}" ]]; then
  if command -v xdg-desktop-menu >/dev/null 2>&1; then
    xdg-desktop-menu uninstall --novendor happ.desktop 2>/dev/null || true
  fi
  rm -f "${DESKTOP_PATH}"
  removed=1
  info "Removed ${DESKTOP_PATH}"
fi

while IFS= read -r -d '' icon_file; do
  rm -f "${icon_file}"
  removed=1
  info "Removed ${icon_file}"
done < <(find "${PREFIX}/share/icons" -type f -name 'happ.png' -print0 2>/dev/null)

if command -v xdg-icon-resource >/dev/null 2>&1; then
  xdg-icon-resource uninstall --novendor --size 256 happ 2>/dev/null || true
  xdg-icon-resource forceupdate 2>/dev/null || true
fi

if [[ -d "${MARKER_DIR}" ]]; then
  rm -rf "${MARKER_DIR}"
  removed=1
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "${PREFIX}/share/applications" 2>/dev/null || true
fi

if [[ "${removed}" -eq 0 ]]; then
  echo "Nothing to remove - Happ does not appear to be installed"
  exit 0
fi

ok "Happ removed successfully"
echo "Settings and daemon state are kept. To remove them too:"
echo "  rm -rf ~/.config/happ ~/.local/share/happ && sudo rm -rf /var/lib/happd"
