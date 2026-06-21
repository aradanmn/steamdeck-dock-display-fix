#!/bin/bash
# predock-probe.sh — ExecStartPre hook for gamescope-session.service
#
# Wait for external display EDID before Gamescope takes DRM master.
# Fixes the amdgpu MST probe race: the DTM TA (Display Topology Management
# Trusted Application, a PSP firmware component) is not ready at early boot,
# causing the DP MST topology probe to silently fail. Affects any MST dock.
# Without this, the external display is blank until you replug the cable.
#
# Install drop-in:
#   ~/.config/systemd/user/gamescope-session.service.d/predock-probe.conf
#   [Service]
#   TimeoutStartSec=90
#   ExecStartPre=/home/deck/.local/bin/predock-probe.sh

MAX_WAIT=45

for i in $(seq 1 $MAX_WAIT); do
    any_connected=0

    for status_file in /sys/class/drm/card0/card0-DP-*/status; do
        [ -f "$status_file" ] || continue
        if [ "$(cat "$status_file" 2>/dev/null)" = "connected" ]; then
            any_connected=1
            connector_dir="$(dirname "$status_file")"
            edid_size=$(wc -c < "${connector_dir}/edid" 2>/dev/null || echo 0)
            if [ "$edid_size" -gt 0 ]; then
                exit 0
            fi
        fi
    done

    # No DP connector connected — no dock, exit immediately (zero delay)
    [ "$any_connected" -eq 0 ] && exit 0
    sleep 1
done

exit 0
