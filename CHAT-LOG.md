# Steam Deck Dock Display Fix — Investigation Chat Log

**Sessions:** 2026-06-20 through 2026-06-21  
**Hardware:** Steam Deck OLED (Galileo), Sceptre O34 ultrawide, CalDigit dock (and others)  
**OS:** SteamOS 3.8.10 build 20260617.1, gamescope 3.16.23.2  
**GitHub issue filed:** [ValveSoftware/SteamOS#2467](https://github.com/ValveSoftware/SteamOS/issues/2467)  
**Participants:** the repo owner ("the user" below), who steered and tested on the hardware, and Claude (Anthropic's AI model, via Claude Code), who did the log analysis and wrote the code. This log is Claude's write-up of the sessions.

---

## The Problem

The Steam Deck OLED connected to any dock (CalDigit and others) exhibited three related display failures:

1. **External display blank on first boot while docked** — cable replug required
2. **External display blank after waking from suspend** — replug or restart required
3. **External display blank mid-session after dock reconnect** — multiple reconnects or manual restart required

The user's framing: *"to me it's all the same issue — Steam doesn't behave well with external displays"*

---

## Investigation

### Symptom 1 — Blank on boot with dock

Pulled kernel logs over SSH. Found the MST topology probe failing silently at boot:

```
kernel: drm_mode_object_add WARNING
```

**Root cause: DTM TA race**

All docks use DisplayPort MST (Multi-Stream Transport). The DTM TA (Display Topology Management Trusted Application) is a PSP firmware component that must initialize before the MST probe runs. At early boot this takes ~35 seconds. If `drm_dp_mst_link_probe_work` runs first, it fails silently and leaves `DP-1` in a `connected` but `edid=0` state — gamescope sees no valid display and renders only to the internal panel.

**Fix: `predock-probe.sh` + ExecStartPre drop-in**

Poll all DP connector EDID files before gamescope takes DRM master. Wait up to 45 seconds for a connected+valid-EDID state. Exit immediately if no dock is connected (zero delay for undocked boot).

```ini
# gamescope-session.service.d/predock-probe.conf
[Service]
TimeoutStartSec=90
ExecStartPre=/home/deck/.local/bin/predock-probe.sh
```

---

### Symptom 2 — Blank after suspend/resume

After sleeping and waking, the external display showed nothing even though SSH confirmed the Deck was awake (DS4 controller reconnected via BT, haptic feedback present).

**Initial investigation:**

```
$ cat /sys/class/drm/card0/card0-DP-1/status
connected
$ wc -c < /sys/class/drm/card0/card0-DP-1/edid
256
$ systemctl --user is-active gamescope-session.target
active
```

Kernel and display hardware were fine. Gamescope was running but not re-driving the external output after resume.

**First approach: system-sleep hook**

Added `/etc/systemd/system-sleep/deck-dock-resume.sh`. Found it never fired — believed at the time that SteamOS writes directly to `/sys/power/state` and bypasses systemd-sleep entirely. Removed the hook.

**Second approach: journalctl watcher service**

```bash
# resume-display-restore.sh (original)
journalctl -f -k --no-pager | grep --line-buffered "PM: suspend exit" | \
while read -r line; do
    sleep 8
    systemctl --user restart gamescope-session.target
done
```

Ran as a persistent `Restart=always` user service. Seemed to work in initial testing.

**Hotplug script (first version)**

Added a udev rule and `dock-display-hotplug.sh` to restart gamescope when an external display connected but had no EDID (the MST probe failure case). This script initially restarted on every hotplug, causing black screens during normal dock connects (Gamescope was handling those fine on its own). Refined to only restart when EDID is missing.

---

### Symptom 3 — WAYLAND_DISPLAY crash loop (2026-06-20 04:48)

**Incident:** Deck auto-suspended at 23:15 while docked, woke at 04:48 (~5.5h later). Both internal and external displays went black and never recovered. SSH showed the Deck was alive.

**Triage:**

```bash
$ systemctl --user show-environment | grep WAYLAND
WAYLAND_DISPLAY=wayland-1

$ journalctl | grep "Failed to connect to wayland socket" | wc -l
149
```

**Root cause: stale WAYLAND_DISPLAY in user manager environment**

`WAYLAND_DISPLAY=wayland-1` was present in the `systemd --user` manager environment, leaked by our nested-KWin work (a separate project in this codebase that creates a `wayland-1` socket). With this variable set, embedded gamescope auto-selects the **nested** backend and attempts to connect to a parent `wayland-1` socket. That socket no longer exists after the session died. Gamescope exits, sddm respawns it, gamescope exits again — forever. 149 failures over ~10 minutes before manual intervention.

**Why it's unrecoverable without intervention:**

`/usr/bin/start-gamescope-session` sanitizes some inherited display environment:

```sh
# /usr/bin/start-gamescope-session line 22
systemctl --user unset-environment DISPLAY XAUTHORITY
```

But it does **not** clear `WAYLAND_DISPLAY`. And `systemctl --user restart gamescope-session.target` bypasses `start-gamescope-session` entirely, so neither path cleans it up.

**Manual fix:**

```bash
systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY
systemctl restart sddm
```

**Key observation:** our `resume-display-restore.service` log showed zero entries — the journalctl watcher never saw the resume event. This is because the `journalctl -f -k` process itself gets frozen during suspend and cannot receive new log events on resume.

---

### GitHub issue filed

Reported the unrecoverable WAYLAND_DISPLAY crash loop to Valve on the existing display issue:

**[ValveSoftware/SteamOS#2467 comment](https://github.com/ValveSoftware/SteamOS/issues/2467#issuecomment-4757313621)**

Key points in the report:
- The polluting `WAYLAND_DISPLAY` came from our own nested compositor work, not a stock Deck scenario
- But any third-party tool, Decky plugin, or nested session could leak the same variable
- The failure mode is severe and unrecoverable
- Suggested fix: add `WAYLAND_DISPLAY` to the `unset-environment` line in `start-gamescope-session`, and/or explicitly pass `--backend drm` to gamescope rather than relying on env-based backend auto-detection

---

### SteamOS 3.8.10 uses systemd-sleep (correction)

While investigating, discovered the earlier assumption was **wrong**: SteamOS 3.8.10 (build 20260617.1) **does** use `systemd-suspend.service` / `systemd-sleep`. Journal evidence:

```
Jun 19 23:15:09 systemd[1]: Starting System Suspend...
Jun 19 23:15:09 systemd-sleep[75557]: Performing sleep operation 'suspend'...
Jun 20 04:48:04 systemd-sleep[75557]: System returned from sleep operation 'suspend'.
Jun 20 04:48:04 systemd[1]: Finished System Suspend.
```

SteamOS ships its own hooks in `/usr/lib/systemd/system-sleep/` (`hibernate-post.sh`, `modules-reload.sh`). This means `/etc/systemd/system-sleep/` hooks **are** a valid and robust resume trigger — invoked by the resume sequence itself, cannot be frozen or missed.

---

### Architecture rewrite

Replaced the journalctl-tail service with a two-part system-sleep hook design:

**`/etc/systemd/system-sleep/deck-display-resume.sh`** (root, fires on `post`)
```sh
[ "$1" = "post" ] || exit 0
su -s /bin/bash deck -c \
    "XDG_RUNTIME_DIR=/run/user/1000 \
     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
     systemctl --user start --no-block resume-display-restore.service"
```
Does not block resume (uses `--no-block`).

**`resume-display-restore.sh`** (oneshot worker)
1. Sleep 8s (give DRM/MST time to re-enumerate)
2. Sanitize env: `unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY`
3. Check if any DP connector is `connected`
4. If docked: restart gamescope. If undocked + session healthy: no action.
5. Log to `/tmp/resume-display-restore.log`

**`resume-display-restore.service`** — `Type=oneshot`, triggered on-demand, no `Restart=`.

---

### Symptom 3 — Steam not rendering despite valid EDID (2026-06-21)

User reported both screens black again. Triage showed:

```
DP-1:  status=connected  dpms=On  edid=256b   ← external detected
eDP-1: status=connected  dpms=Off edid=256b   ← internal off (normal when docked)
gamescope-session.target: active
WAYLAND_DISPLAY: (not set)
wayland-socket failures: 0
```

No crash loop. No stale env. Gamescope log showed it correctly detected and selected DP-1:

```
drm: Connector DP-1 -> SPT - Sceptre O34
drm: selecting connector DP-1
drm: selecting mode 3440x1440@60Hz
wlserver: Updating mode for xwayland server #0: 3440x1440@60
wlserver: Updating mode for xwayland server #0: 1920x1080@60
```

(The 1920×1080 revert is normal — Steam Big Picture UI renders at 1920×1080, gamescope scales to 3440×1440.)

Steam was running (PID in `steam-launcher.service`), gamescope was rendering, but nothing appeared on screen. User had already tried replugging the dock twice — old hotplug script didn't trigger because EDID was present.

**Root cause:** The old hotplug script only restarted on missing EDID. When Steam fails to attach to a newly-hotplugged output despite gamescope detecting it correctly, a restart is needed but wasn't triggered.

**Fix: always restart on DP connect**

Updated `dock-display-hotplug.sh` to restart gamescope whenever any DP connector reports `connected` — not just on missing EDID. The 60-second cooldown stamp prevents rapid-fire triggers. This covers both failure modes in one policy:

| Scenario | Old behaviour | New behaviour |
|----------|---------------|---------------|
| MST probe race (EDID missing) | Restart ✅ | Restart ✅ |
| Steam not rendering (EDID present) | No restart ❌ | Restart ✅ |
| Disconnect event (status=disconnected) | No restart ✅ | No restart ✅ |
| Rapid reconnects within 60s | Restart loop ❌ | Stamp prevents ✅ |

---

## What still requires manual action

**Sceptre O34 Auto Power Off:** When the Deck suspends, the DP signal stops. The Sceptre counts down its "No Signal Auto Off" timer and fully powers off — HPD goes low, the kernel sees `DP-1: status=disconnected edid=0`. No software command from the Deck can wake a display with HPD low. Workaround: go into the Sceptre OSD and disable "Auto Power Off." Until then, a cable replug or pressing the monitor's power button is required after a suspend where the display powered fully off.

---

## File reference

| File | Installed to | Role |
|------|--------------|------|
| `predock-probe.sh` | `~/.local/bin/` | Waits for EDID before gamescope starts (boot MST race) |
| `predock-probe.conf` | `~/.config/systemd/user/gamescope-session.service.d/` | Hooks predock-probe as ExecStartPre |
| `99-deck-dock-display.rules` | `/etc/udev/rules.d/` | udev trigger for DRM hotplug |
| `dock-display-hotplug.sh` | `~/.local/bin/` | Restarts gamescope on DP connect; sanitizes env |
| `deck-display-resume.sh` | `/etc/systemd/system-sleep/` | Robust resume trigger via systemd-sleep |
| `resume-display-restore.sh` | `~/.local/bin/` | Oneshot worker: sanitize env → restart if docked |
| `resume-display-restore.service` | `~/.config/systemd/user/` | Oneshot service unit for the worker |
| `install.sh` | run on Deck | Deploys all of the above |

---

## Lessons learned

- **MST + amdgpu has a DTM TA init race** that silently fails the MST probe at boot. Polling for EDID before gamescope starts is the only robust fix.
- **SteamOS 3.8.10 uses systemd-sleep** (not `/sys/power/state` directly). `/etc/systemd/system-sleep/` hooks are the right resume trigger — not journalctl tailing.
- **`WAYLAND_DISPLAY` in the systemd user env is fatal to gamescope.** Any leaked value forces the nested backend and causes an unrecoverable crash loop. Clear it before every gamescope restart.
- **Steam doesn't reliably attach to a newly-detected external output.** Even with valid EDID and gamescope selecting the connector, Steam can end up rendering nowhere. A restart is the only reliable fix.
