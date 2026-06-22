# Cursor-Sync Runbook

The one document for keeping "open any note on any device, land where you left off" working —
forever, across any number of devices. Everything here is driven by **one script**:
`scripts/sync-reset.ps1`.

---

## 0. The model (read once)

- **RCP-E** (the plugin) saves each device's reading position to `cursor-state/{deviceId}.json`.
  Each device writes **only its own** file. On note-open it merges all device files and restores
  the newest position. Single-writer files = **structurally impossible to conflict**.
- **LiveSync → CouchDB** (on the laptop) is just the _pipe_ that copies those files between devices.
  CouchDB itself runs as a **Docker container inside WSL Ubuntu** (`obsidian-livesync-couchdb`,
  `restart: unless-stopped`). Windows reaches it through a **stable bridge** — see §1c.
- **The laptop (`C:\notes1`) is always the source of truth.** Every reset re-uploads the laptop
  and every other device fetches it. Never the other way around.

Two things, and only two, must be true for sync to work:

1. The pipe delivers `cursor-state/*.json` (CouchDB lean, unlocked, all real nodes accepted).
2. The merge picks the right position (handled in plugin code — see "The snap-back fix" below).

---

## 1. Daily health check (safe, read-only)

```powershell
pwsh scripts/sync-reset.ps1 -Action doctor
```

Auto-discovers every connected adb device (phone/tablet) + the laptop and reports:

- CouchDB size + lock state + any **ghost nodes** (dead vault identities).
- A per-file **md5 comparison** of `cursor-state/*.json` across **all** devices.
  `OK` = byte-identical everywhere. `DIFF` = that file hasn't propagated → the pipe is stuck.

Connect more devices (just plug in / `adb connect`) and re-run — it scales to N devices with zero
config. Each device also keeps its **own** logs (`rcp-enhanced-logs/{deviceId}.log` and
`cursor-state/.diag-{deviceId}.json`), so any device is debuggable in isolation.

---

## 1b. Sync stuck / paused? — THE ONE-COMMAND FIX (use this 99% of the time)

This is your "reboot it" button. No USB. It reconnects to the phone + tablet over Tailscale,
re-asserts the correct sync settings, restarts their Obsidian so replication re-establishes,
and prints the health check so you can watch it converge.

```powershell
pwsh scripts/sync-kick.ps1          # fix phone + tablet, verify
pwsh scripts/sync-kick.ps1 -All     # ALSO restart the laptop's Obsidian
```

It does NOT touch CouchDB or your notes — only wakes the sync. After it runs, **glance at a note
on each phone/tablet for a few seconds** (mobile only syncs in the foreground). That's it.

After a phone/tablet **reboot**, wireless adb resets — plug it into USB once and run
`pwsh scripts/adb-net.ps1 -Enable`, then unplug. Cable-free again.

## 1c. CouchDB unreachable / phone+tablet get 502 — the WSL bridge

CouchDB lives in **WSL Docker**, so two things can take the whole pipe down:

1. **WSL isn't running** (after a reboot — WSL doesn't auto-start). Symptom: `127.0.0.1:5984`
   refused everywhere; analyzer says `CouchDB UNREACHABLE`.
2. **The WSL2 localhost relay wedges** (Win10). Symptom: CouchDB is healthy *inside* WSL but
   Windows gets connection-refused on `127.0.0.1:5984`, and the phone/tablet get **502** over
   Tailscale. The relay binds the port but stops forwarding.

Both are now handled automatically. A scheduled task **`ObsidianCouchBridge`** runs
`scripts/sync-couch-bridge.ps1` **at logon and every 30 min** (elevated). Each run:

- starts WSL + waits for CouchDB to be healthy,
- reads the current WSL VM IP (it changes every boot), and
- (re)points a stable loopback bridge **`127.0.0.1:5994` → `<WSL-IP>:5984`** that never uses
  the flaky relay. Tailscale Serve proxies `https://<host>.ts.net/` → `127.0.0.1:5994`.

**Manual recovery (rarely needed):**

```powershell
# Re-assert the bridge right now (UAC prompt — needs admin for netsh portproxy)
Start-Process pwsh -Verb RunAs -ArgumentList '-File C:\obsidian-remember-cursor-position\scripts\sync-couch-bridge.ps1'
# Watch it: debug-reports\bridge.log  (look for "=== bridge OK ===")
```

**One-time hardening (recommended):** point the **laptop's** Obsidian LiveSync at the bridge so
it's immune to the relay too — Settings → Self-hosted LiveSync → Remote → set URI to
`http://127.0.0.1:5994/`, Test, Apply. (Phone/tablet already use the bridge via Tailscale.)

### Why it now survives a reboot (the 2026-06-21 outage cause)

A Windows restart left WSL stopped and nobody restarted it → CouchDB was down 27h. The full
auto-start chain is now:

```
power on  →  Windows auto-login (AutoAdminLogon, no-password Admin acct)
          →  ObsidianCouchBridge logon task runs sync-couch-bridge.ps1
          →  `wsl` cold-starts Ubuntu  →  systemd (wsl.conf [boot] systemd=true)
          →  docker.service (enabled)  →  CouchDB container (restart: unless-stopped)
          →  portproxy 127.0.0.1:5994 → <WSL-IP>:5984 set + verified
```

Every link is automatic and was tested from a fully-stopped WSL (recovers in ~10s). The task
also re-runs every 30 min, so a mid-session WSL restart or relay wedge self-heals too.

To undo auto-login later: set `AutoAdminLogon=0` under
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.

### Backups

`scripts/sync-couch-backup.ps1` tars the CouchDB volume (`livesync_couchdb-data`) to
`C:\notes1-couchdb-backups\couchdb-<timestamp>.tgz`. The **ObsidianCouchBackup** task runs it
**daily 02:00 + at every logon**, keeping the newest 14. Restore: stop the container, wipe the
volume, untar a snapshot back into it.

### Re-install the tasks (if ever deleted)

```powershell
Start-Process pwsh -Verb RunAs -ArgumentList '-File C:\obsidian-remember-cursor-position\scripts\_install_bridge_task.ps1'
Start-Process pwsh -Verb RunAs -ArgumentList '-File C:\obsidian-remember-cursor-position\scripts\_install_backup_task.ps1'
```

---

## 2. The deep reset (RARE — only for chunk errors / bloat, not normal stalls)

This is the **"reset everything to a clean slate"** procedure. It reclaims all CouchDB bloat and
unifies every device onto one fresh document lineage (the thing that fixes "device X won't push").

> Backup first; it's automatic but run it explicitly so you have a labelled snapshot.

```powershell
# 1. Snapshot configs + cursor-state + CouchDB milestone
pwsh scripts/sync-reset.ps1 -Action backup

# 2. CLOSE Obsidian on EVERY device (laptop, phone, tablet). This is mandatory —
#    a running Obsidian rewrites its config on exit and undoes step 3.

# 3. Normalize config on the laptop + every connected device (calms log churn, kills history)
pwsh scripts/sync-reset.ps1 -Action patch

# 4. Wipe CouchDB clean (remote only; the laptop vault on disk is never touched)
pwsh scripts/sync-reset.ps1 -Action wipe -Yes
```

Then the **two clicks only Obsidian can do**:

5. **Laptop:** open Obsidian → Command palette → **"Self-hosted LiveSync: Overwrite remote"**.
   This uploads the laptop vault as the fresh truth and locks the remote.
6. **Each other device:** open Obsidian → on the lock dialog choose
   **"Fetch everything from the remote (rebuild local)"**. The device adopts the clean lineage.
   (Devices that are off/away just do this next time you open them — no rush.)

Finally:

```powershell
# 7. After every device has fetched: clear the lock + drop ghost nodes
pwsh scripts/sync-reset.ps1 -Action unlock

# 8. Confirm it worked
pwsh scripts/sync-reset.ps1 -Action verify   # want: all OK, unlocked, active < 60MB
```

**Canary test:** phone → open an Udaan note, scroll to a question, wait ~10s, switch notes.
Laptop → open the same note → it lands at that question. `doctor` shows that file `OK`.

---

## 3. Adding a new device (the 5th, 10th, 100th)

1. Install Obsidian + the RCP-E plugin + LiveSync on the device.
2. Point LiveSync at the same CouchDB (Tailscale HTTPS URL) with the **same E2EE passphrase**.
3. First sync: **"Fetch everything from the remote (rebuild local)"** (never "Overwrite remote"
   from a new device — that would clobber everyone).
4. It auto-creates its own `cursor-state/{newId}.json` and its own log file. Nothing else to do.
5. `pwsh scripts/sync-reset.ps1 -Action doctor` now lists it automatically.

There is no per-device ceiling: every device is a single-writer of its own file, so 100 devices =
100 conflict-free files.

---

## 4. The snap-back fix (plugin behavior, v2.1.5+)

Symptom: "I scroll down, it jumps back to the top / a default position from somewhere."

Cause: a stale remote position with a skewed-newer wall-clock used to override your live scroll.
Fixed in code (no settings needed):

- **Active-reading guard** (`main.ts`): while you're touching a note, no remote position can
  override it for `ACTIVE_INTERACTION_GUARD_MS` (10s) after your last move. Uses the local clock
  only, so cross-device clock skew can't defeat it.
- **Weak-default guard** (`state-logic.ts`): a "top-of-note / scroll-0" incoming state can never
  overwrite a substantial reading position, regardless of timestamps.

If it ever recurs, grab the losing device's `rcp-enhanced-logs/{id}.log` and search for
`Merged state held` / `apply-rejected` to see exactly which device's entry tried to win and why.

---

## 5. Golden rules (the lessons, distilled)

- **Laptop is truth.** New/other devices **Fetch**; only the laptop **Overwrites**.
- **Edit configs only while Obsidian is CLOSED** (a running app overwrites `data.json` on exit).
- **Never run two sync tools** (LiveSync + Syncthing) on one vault. Pick one. We use LiveSync.
- **Never register two vaults** against one CouchDB on one device (the old "Vault (1)" flood).
- After a reboot on Android, **reconnect Tailscale** before expecting sync.
- A device that won't sync despite correct config + network is usually a broken runtime →
  reinstall Obsidian, then **Fetch**.
- Keep `useHistory:false`, `writeLogToTheFile:false`, and the full `syncIgnoreRegEx` on **every**
  device. `-Action patch` enforces this everywhere in one shot.

If sync ever seems stuck — run ONE thing

pwsh scripts/sync-kick.ps1
That's your "reboot it" button. Over Tailscale (no USB, no cables), it: reconnects to the phone + tablet → re-asserts the correct settings → restarts their sync → shows you the health check. Then just glance at a note on each phone/tablet for a few seconds. Done — usually ~40 seconds total.

If the laptop itself seems stuck too, add -All:

pwsh scripts/sync-kick.ps1 -All
Your whole cheat sheet (only 4 commands, ever)
Situation Command
Sync stuck / paused pwsh scripts/sync-kick.ps1
Just checking — is everything in sync? pwsh scripts/adb-net.ps1 -Doctor
Phone/tablet was rebooted (adb won't connect) USB once → pwsh scripts/adb-net.ps1 -Enable → unplug
Deep corruption (chunk errors / GB bloat — rare) open SYNC-RUNBOOK.md, run the reset section
All committed and documented in SYNC-RUNBOOK.md, so it's never lost.

What "normal" looks like now
You shouldn't even need the button most days. With syncOnSave + 30-second periodic on all three devices, the everyday experience is: scroll on one device → it shows up on the others within a few seconds (and a backgrounded phone/tablet catches up the moment you open it). The kick button is just insurance for the rare hiccup — the equivalent of restarting an app that misbehaved.

Why it kept happening before (so you trust it's actually fixed)
The real culprit, underneath all the symptoms, was that the continuous live connection doesn't survive over Tailscale — and your config had no fallback, so any drop = silent freeze until a restart. That's now fixed at the root on every device (push-on-save + pull-every-30s), which is why this round is different from all the previous attempts.
