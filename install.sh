#!/usr/bin/env bash
# install.sh — deploy Steam Deck dock display fixes.
# Run this ON the Steam Deck (not on your PC).
# Needs sudo for /etc files (udev rule + system-sleep hook).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
USER_BIN="$HOME/.local/bin"
USER_SYSD="$HOME/.config/systemd/user"
DROPIN="$USER_SYSD/gamescope-session.service.d"

mkdir -p "$USER_BIN" "$USER_SYSD" "$DROPIN"

# Disable any old persistent journalctl-tail version of the service first.
systemctl --user disable --now resume-display-restore.service 2>/dev/null || true

# User-space scripts and service unit
install -m 0755 "$HERE/predock-probe.sh"           "$USER_BIN/predock-probe.sh"
install -m 0755 "$HERE/dock-display-hotplug.sh"    "$USER_BIN/dock-display-hotplug.sh"
install -m 0755 "$HERE/resume-display-restore.sh"  "$USER_BIN/resume-display-restore.sh"
install -m 0644 "$HERE/resume-display-restore.service" "$USER_SYSD/resume-display-restore.service"
install -m 0644 "$HERE/predock-probe.conf"         "$DROPIN/predock-probe.conf"

systemctl --user daemon-reload

# Root: udev rule + system-sleep hook
sudo mkdir -p /etc/udev/rules.d /etc/systemd/system-sleep
sudo install -m 0644 "$HERE/99-deck-dock-display.rules"  /etc/udev/rules.d/99-deck-dock-display.rules
sudo install -m 0755 "$HERE/deck-display-resume.sh"      /etc/systemd/system-sleep/deck-display-resume.sh
sudo udevadm control --reload-rules

echo ""
echo "Installed:"
echo "  $USER_BIN/predock-probe.sh            (boot MST race fix — waits for EDID)"
echo "  $DROPIN/predock-probe.conf  (ExecStartPre drop-in)"
echo "  $USER_BIN/dock-display-hotplug.sh     (hotplug → gamescope restart)"
echo "  /etc/udev/rules.d/99-deck-dock-display.rules"
echo "  $USER_BIN/resume-display-restore.sh   (oneshot resume worker)"
echo "  $USER_SYSD/resume-display-restore.service"
echo "  /etc/systemd/system-sleep/deck-display-resume.sh (resume trigger)"
echo ""
echo "Test resume worker without restarting gamescope:"
echo "  RESUME_RESTORE_DRYRUN=1 $USER_BIN/resume-display-restore.sh && cat /tmp/resume-display-restore.log"
