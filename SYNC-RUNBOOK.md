# Cursor-Sync Runbook

The one document for keeping "open any note on any device, land where you left off" working —
forever, across any number of devices. Everything here is driven by **one script**:
`scripts/sync-reset.ps1`.

---

## 0. The model (read once)

- **RCP-E** (the plugin) saves each device's reading position to `cursor-state/{deviceId}.json`.
  Each device writes **only its own** file. On note-open it merges all device files and restores
  the newest position. Single-writer files = **structurally impossible to conflict**.
- **LiveSync → CouchDB** (on the laptop) is just the *pipe* that copies those files between devices.
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

## 2. The reset (when sync is stuck or bloated)

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
