# steamdeck-dock-display-fix

Fixes external display reliability on a docked Steam Deck OLED (SteamOS Game Mode / gamescope). Three failure modes addressed:

1. **Blank on boot while docked** — external display needs cable replug
2. **Blank after suspend/resume** — Gamescope doesn't re-drive the external output
3. **Blank after dock reconnect mid-session** — Steam doesn't attach to the newly-detected display

Tested on: Steam Deck OLED (Galileo), SteamOS 3.8.10, gamescope 3.16.23.2, Sceptre O34 via CalDigit dock (DP MST). Should work with any DP-alt-mode dock.

See [CHAT-LOG.md](CHAT-LOG.md) for the full investigation, root cause analysis, and what was tried.

---

## Quick install

```sh
git clone https://github.com/aradanmn/steamdeck-dock-display-fix
cd steamdeck-dock-display-fix
./install.sh
```

Needs `sudo` for the `/etc` files (udev rule + system-sleep hook). Uses the `deck` password.

---

## What it installs

### Fix 1 — Boot MST probe race (`predock-probe.sh`)

The DTM TA (PSP firmware component managing DP topology) isn't ready at early boot. The kernel's MST probe runs first and fails silently, leaving `DP-1` in a `connected` but `edid=0` state. Gamescope sees no external display.

**Fix:** poll DP connector EDID before Gamescope takes DRM master. Waits up to 45s for a connected+EDID-valid state. Exits immediately if undocked (no delay).

Installed as `ExecStartPre` via a systemd drop-in on `gamescope-session.service`.

### Fix 2 — Suspend/resume blank (`deck-display-resume.sh` + `resume-display-restore.sh`)

After suspend, Gamescope doesn't always re-drive the external output on resume.

**Fix:** a `/etc/systemd/system-sleep/` hook fires on resume (invoked by the resume sequence itself — can't be frozen like a journalctl tail). It starts a oneshot worker that:
1. Waits 8s for DRM/MST to re-enumerate
2. Clears any stale `WAYLAND_DISPLAY`/`DISPLAY`/`XAUTHORITY` from the systemd user environment (**critical** — see below)
3. Restarts `gamescope-session.target` if an external display is connected

> **SteamOS 3.8.10 note:** this build uses `systemd-suspend.service` and `systemd-sleep` (ships hooks in `/usr/lib/systemd/system-sleep/`). The `/etc/systemd/system-sleep/` path works correctly.

Test without restarting Gamescope:
```sh
RESUME_RESTORE_DRYRUN=1 ~/.local/bin/resume-display-restore.sh && cat /tmp/resume-display-restore.log
```

### Fix 3 — Dock hotplug blank (`dock-display-hotplug.sh` + udev rule)

After plugging in the dock (or reconnecting it), Gamescope detects the display and selects the correct mode, but Steam doesn't attach to render to it.

**Fix:** restart `gamescope-session.target` (which restarts Steam too) on every DP connect event. A 60-second cooldown stamp prevents rapid-fire triggers.

---

## The WAYLAND_DISPLAY crash loop

> **TL;DR:** A leaked `WAYLAND_DISPLAY=wayland-1` in the systemd user environment makes gamescope crash-loop forever (both screens black, unrecoverable). Every restart path in these scripts clears it first.

When `WAYLAND_DISPLAY` is set in the `systemd --user` manager environment, the embedded gamescope auto-selects the **nested** backend and tries to connect to a parent `wayland-1` socket. If that socket doesn't exist, gamescope exits — sddm immediately respawns it into the same failure. We observed 149 crash-loop iterations before manual intervention.

`/usr/bin/start-gamescope-session` clears `DISPLAY` and `XAUTHORITY` (line 22) but not `WAYLAND_DISPLAY`. And `systemctl --user restart gamescope-session.target` bypasses `start-gamescope-session` entirely.

**Manual recovery if this happens:**
```sh
systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY
sudo systemctl restart sddm
```

Reported upstream: [ValveSoftware/SteamOS#2467](https://github.com/ValveSoftware/SteamOS/issues/2467)

---

## Known limitation

**Monitor Auto Power Off:** when the Deck suspends, the DP signal stops. If your monitor's "No Signal Auto Off" feature is enabled, it fully powers down — HPD goes low and the kernel sees `DP-1: status=disconnected`. No software can wake a display with HPD low. Disable "Auto Power Off" in your monitor's OSD. Until then, press the power button or replug the cable after a long suspend.

---

## File reference

| File | Installed to | Role |
|------|--------------|------|
| `predock-probe.sh` | `~/.local/bin/` | Polls EDID before Gamescope starts |
| `predock-probe.conf` | `~/.config/systemd/user/gamescope-session.service.d/` | ExecStartPre drop-in |
| `99-deck-dock-display.rules` | `/etc/udev/rules.d/` | udev DRM hotplug trigger |
| `dock-display-hotplug.sh` | `~/.local/bin/` | Restarts Gamescope on DP connect |
| `deck-display-resume.sh` | `/etc/systemd/system-sleep/` | Resume trigger hook |
| `resume-display-restore.sh` | `~/.local/bin/` | Oneshot resume worker |
| `resume-display-restore.service` | `~/.config/systemd/user/` | Oneshot service unit |
