# Obsidian Cross-Device Cursor Sync — Full Status Report
_Prepared 2026-06-10. Shareable hand-off document._

---

## 1. THE GOAL (what we are trying to achieve)

One continuous reading position across all of the user's devices. Concretely:

> Open any note on any device and land exactly where you left off on any other device — automatically, within seconds, no cables, no manual steps.

Example: read an "Udaan Batch 11" note to Question 17 on the **phone**; later open the same note on the **laptop** and it opens at Q17. Scroll to Q59 on the **tablet**; the laptop and phone show Q59 next time they open it. "Newest position wins."

This is a **personal, single-user** setup (one person, multiple devices), not a multi-user collaboration.

---

## 2. SYSTEM ARCHITECTURE

### Devices (4)
| Role | OS | Vault path | RCP-E device id | LiveSync node id |
|------|-----|-----------|-----------------|------------------|
| Master laptop (hub, runs CouchDB) | Windows | `C:\notes1` | `vyovb870` | `3zo5uaomwq` |
| 2nd laptop | Windows | (its own) | `ytt2gvef` | — |
| Phone (Galaxy S24+, adb `RZCY11EKL7E`) | Android | `/storage/emulated/0/Documents/Test` | `hvmodycj` | `1sm68z1vc8` |
| Tablet (Galaxy Tab A9 SM-X115, adb `R9ZY90L2DVM`) | Android | `/storage/emulated/0/ObsidianVault` | `bri9e1q4` | `ojyxug2rpp` |

Vault size: ~10 MB, ~143 markdown notes.

### Software stack
- **Obsidian** + plugin **"Remember Cursor Position — Enhanced" (RCP-E) v2.1.4**. RCP-E saves each device's scroll/cursor to `cursor-state/{deviceId}.json` (each device writes **only its own** file). On note-open it **merges all four device files** and restores the newest position. It logs to `rcp-enhanced-logs/` (should NOT sync).
- **Sync transport = Self-hosted LiveSync** (Obsidian plugin) → **CouchDB** running in Docker/WSL on the master laptop: `http://127.0.0.1:5984`, db `obsidian-vault`, user/pass `obsidian` / `11111111`.
- **Tailscale** lets the phone/tablet reach CouchDB. CouchDB is exposed via **Tailscale Serve** at `https://desktop-vvtrbng.taila398c1.ts.net` (proxies to `127.0.0.1:5984`). NOT the raw Tailscale IP.
- Key files per vault: `cursor-state/{id}.json` (synced), `rcp-enhanced-logs/` (ignored), `.obsidian/plugins/obsidian-livesync/data.json` (LiveSync config), `.obsidian/plugins/remember-cursor-position-enhanced/data.json` (RCP-E config).

---

## 3. THE ORIGINAL PROBLEM (symptoms)

- Set a position on the phone → the laptop/tablet did not update (and vice-versa).
- Phone "fast fetch" tried to download **2.9 GB → 5 GB → 8 GB+** for a 10 MB vault.
- "Broken file / inconsistent metadata, cannot be fixed on this device" dialogs.
- `redflag2` rebuild ended with **"No remote replicator configuration found"** (fatal).
- USB cable was being used as a workaround to copy `cursor-state` between devices.

RCP-E itself worked fine on each device locally. The failure was the **delivery pipe (LiveSync/CouchDB)** not moving `cursor-state` reliably, plus massive CouchDB bloat.

---

## 4. ROOT CAUSES FOUND (the real diagnoses)

1. **Invalid JSON silently blanked the LiveSync config.** A buggy regex in `scripts/reset-livesync-from-laptop.ps1` wrote `\.` (an illegal JSON escape) into `syncIgnoreRegEx`. Obsidian loads `data.json` with `JSON.parse`, which throws on `\.`, so LiveSync fell back to a blank config (`isConfigured:true` but empty connection) → "no remote replicator." **This was the recurring "it keeps breaking" cause.**

2. **All automatic sync triggers were OFF** — `liveSync:false`, `syncOnSave:false`, `syncOnStart:false`, `periodicReplication:false`. LiveSync only moved data on a manual "Replicate now."

3. **RCP-E was flooding LiveSync.** With `logToFile:true` + `debugLogging:true` + `saveDebounceMs:200`, RCP-E wrote a debug log every ~2 s and rewrote the cursor file ~5×/10 s. That churn drove the replicator into permanent **"Replication paused"**, so nothing pushed.

4. **CouchDB was bloated to 32,878 documents / 11.4 GB** for a 10 MB vault — caused by `useHistory:true`, no deleted-metadata cleanup, and months of **Syncthing + LiveSync running together** on the same vault (which also left 239+ `.sync-conflict-*` / `.syncthing*` files).

5. **The LiveSync "lock" (biggest late discovery).** "Overwrite remote"/rebuild sets `locked:true` in the CouchDB doc `_local/obsydian_livesync_milestone` and restricts `accepted_nodes`. While locked, **no device can push** (silently — the device writes locally so its `storeRevision` climbs, but CouchDB `update_seq` stays frozen and nothing reaches other devices).

6. **Rebuild creates NEW document lineages.** After a rebuild, a device still holding the OLD revision lineage for a file cannot push it (the revisions don't reconcile). It must "Fetch everything from the remote" to adopt the rebuilt lineage.

7. **Two vaults syncing the same CouchDB on the tablet.** During the Android folder-picker fight, the tablet ended up with two registered vaults. One had an un-patched config (`logToFile:true`, empty `syncIgnoreRegEx`, `useHistory:true`) and **flooded CouchDB from 11.5 MB → 134 MB in minutes** by syncing its constantly-growing debug log with full history.

8. **Android / Samsung gotchas:** the Samsung SAF folder-picker refuses to select `Documents/` and its subfolders (must use an internal-storage-root folder like `/sdcard/ObsidianVault`); clearing `com.google.android.documentsui` cache broke the picker until a reboot; `pm clear` resets the per-vault community-plugin "trust" (plugins must be re-enabled after); Tailscale must be reconnected after every reboot (`UnknownHostException` = Tailscale down).

9. **Deep runtime stall.** Both Android devices reached a state where LiveSync would not replicate despite correct config + working network + enabled plugins (no `livesync_log` written, redflag files never consumed). The proven fix was **uninstalling and reinstalling Obsidian** (cleared the broken WebView/IndexedDB runtime).

---

## 5. WHAT WAS DONE (fixes applied)

**Config / database:**
- Restored the good LiveSync `data.json` from backup and **repaired the invalid `\.` JSON escape** (→ `\\.`), then re-validated.
- **Wiped and rebuilt CouchDB** via "Overwrite remote" from the laptop: **32,878 docs / 11.4 GB → ~9,300 docs / ~15 MB**.
- Patched LiveSync config on every device: `liveSync:true`, `syncOnStart:true`, `useHistory:false`, `skipOlderFilesOnSync:false`, `automaticallyDeleteMetadataOfDeletedFiles:7`, `syncIgnoreRegEx = ^rcp-enhanced-logs/|^cursor-state/\.diag-|^livesync_log`.
- **Calmed RCP-E** on every device: `logToFile:false`, `debugLogging:false`, `saveDebounceMs:1500` (kept `reloadOnExternalChange` + `aggressiveCrossDeviceSync`).
- Turned off LiveSync `writeLogToTheFile` on the laptop and added `livesync_log_*.md` to the ignore (the log files were themselves syncing and conflicting).

**Tablet recovery (most involved):**
- Removed Syncthing debris (`.stfolder`, `.stignore`, `.stversions`, `.sync-conflict-*`).
- Worked around the Samsung folder-picker block by moving the vault to `/sdcard/ObsidianVault` and **rebooting** the tablet (a `documentsui` cache clear had broken the picker).
- After the deep runtime stall, **uninstalled + reinstalled Obsidian**, re-added the vault, re-enabled community plugins.
- Consolidated from the accidental multiple vaults down to **one clean vault** (`ObsidianVault`); deleted the flooding `Vault (1)` and all empty junk folders.

**Lock / lineage:**
- **Cleared the CouchDB lock** via the API: set `locked:false` and added all real nodes to `accepted_nodes` in `_local/obsydian_livesync_milestone` (script `scripts/_unlock.py`).

**Phone recovery:**
- Force-stopped + patched config, added the phone node to `accepted_nodes`, attempted fetch/redflag3, and finally **uninstalled + reinstalled Obsidian**, re-added `Documents/Test`, re-enabled plugins, re-patched config.

**Verification method used throughout:** watch CouchDB `update_seq` (climbs on every change), compare md5 of each `cursor-state/{id}.json` across devices (identical = in sync), check `_local/obsydian_livesync_milestone` (`locked`, `accepted_nodes`), read `livesync_log_*.md` (per-device replication log) and `rcp-enhanced-logs/*.log` (RCP-E's own decisions).

**Proof achieved:** the phone's `hvmodycj.json` propagated **byte-identical** to the laptop with no USB; laptop ↔ tablet later confirmed byte-identical and **automatic** (live).

Helper scripts written (in `scripts/`): `_fix_config.py` (repair invalid JSON + patch), `_enable_sync.py` (liveSync/logging), `_calm_rcpe.py` (quiet RCP-E), `_unlock.py` (clear the lock). Backups of every changed config and a full vault copy are under `debug-reports/` and `C:\notes1-FULLBACKUP-*`.

---

## 6. CURRENT STATE

- ✅ **Laptop ↔ tablet: clean, automatic, two-way cursor sync.** Verified byte-identical, lock cleared, no bloat growth, `useHistory:false`.
- ⚠️ **Phone: pulls fine and pushes some data, but its own `cursor-state/hvmodycj.json` will not continuously push to the others.** This survived config fixes, restart, `accepted_nodes` add, fetch, redflag3, AND a full Obsidian reinstall. After a reinstall it pushes the initial sync once (`update_seq` jumped +141), then "Replication paused" and stops reacting to new `hvmodycj` writes. Suspected cause: the `hvmodycj` document lineage diverged at the rebuild and that divergence persists.
- ⚠️ **CouchDB carries ~140 MB orphan-chunk bloat** from the `Vault (1)` flood. It will not grow further, but compaction can't reclaim it (orphaned chunks); only a fresh rebuild will.
- ❓ **2nd laptop (`ytt2gvef`): not re-verified this session.**

---

## 7. REMAINING / OPEN ISSUES

### 7a. Phone outbound push stuck (primary)
The phone does not reliably propagate its own reading positions to the other devices (see Current State). Everything else about the phone works (it receives others' positions).

### 7b. "Udaan Batch 11 note #7 resets to a default state" (NEW, user-reported)
Symptom: scroll note #7 in `Udaan Batch 11/` on the phone; it briefly holds, then **resets to a default/top position** "from somewhere."

Most likely explanation (consistent with 7a): the phone saves the new scroll to `hvmodycj.json` locally, but **that push is stuck**, so it never reaches the others. Meanwhile RCP-E (with `reloadOnExternalChange` + `aggressiveCrossDeviceSync`) **pulls** the other devices' `cursor-state` files, one of which still holds note #7 at an old/default position (e.g. line 0). If that incoming entry is treated as "newer" (timestamp/hybrid-clock skew between devices), RCP-E **applies it over the phone's fresh scroll** → the view snaps back to the "default." So the "default state" is coming from **another device's stale entry for that note**, winning the merge because the phone's newer position can't propagate and/or because of clock skew.

To confirm: inspect the `notes` entry for that note's hash across all four `cursor-state/*.json` files (compare `lastModified`/`revision` and the cursor line) — the device whose entry is "winning" with a low/zero line is the source of the "default."

This is partly a transport problem (7a) and partly an RCP-E **merge/clock** edge case. Note: the merge logic is RCP-E's and is independent of the sync tool, so it could persist after any transport change unless the stale entry is overwritten and clocks are consistent.

### 7c. CouchDB ~140 MB bloat (cosmetic but real)
Reclaim only via a clean rebuild.

---

## 8. RECOMMENDED PATHS FORWARD (pick one)

### Option A — Stay on LiveSync, do one clean rebuild (rested)
1. On the master laptop: "Overwrite remote" rebuild (resets **all** document lineages and reclaims the 140 MB).
2. On each other device: handle the lock dialog with **"Reset synchronization on this device"** (= fetch the rebuilt remote), then **"Unlock the remote database"** once all have fetched (or clear `locked:false` via `_unlock.py`).
3. Verify `update_seq` flows and md5 of each `cursor-state` file matches across devices.
This should fix the phone's `hvmodycj` push (unified lineage) and likely 7b too.

### Option B — Migrate to Syncthing (recommended for this all-Android+Windows lineup)
LiveSync's hardest failures (lock, lineage, bloat, rebuilds) are **CouchDB concepts that don't exist in Syncthing.** Because each `cursor-state/{deviceId}.json` has a **single writer**, Syncthing cannot conflict on them (structurally zero-conflict). Plan:
1. Uninstall the LiveSync plugin on all 4 devices (never run both at once — that was the original disaster).
2. Install Syncthing (SyncTrayzor on Windows, Syncthing-Fork on Android).
3. Hub-and-spoke with the always-on master laptop (ideally pair to **both** laptops for resilience; optionally phone↔tablet directly).
4. Apply an **ignore list** so per-device churn doesn't create conflict files: ignore `.obsidian/workspace*.json`, `.obsidian/cache`, `.trash`, `rcp-enhanced-logs`, `cursor-state/.diag-*`, `.stversions`; sync the notes + `cursor-state/*.json` + `.obsidian/plugins/`.
- Trade-off: ~a-few-seconds latency (file sync) instead of sub-second; no iOS support (not needed here, all devices are Android/Windows); every device keeps a full local copy so a dead hub loses nothing — only delays.
- Caveat: issue 7b (the merge picking a stale "default") is RCP-E behavior and could persist if it's a clock-skew/merge bug rather than purely the stuck push — worth confirming after migration.

---

## 9. KEY LESSONS (so nobody repeats them)
- A single invalid `\.` in `data.json` silently disables LiveSync (JSON.parse throws → blank config).
- Editing `data.json` only sticks while **Obsidian is CLOSED** (a running Obsidian overwrites it on exit).
- "Overwrite remote" **locks** the database (`_local/obsydian_livesync_milestone.locked`); other devices must Fetch, then someone Unlocks.
- Never run **two vaults** against one CouchDB on one device, and never run **Syncthing + LiveSync together**.
- A device that won't replicate despite perfect config is usually a broken **runtime** → reinstall Obsidian.
- `redflag2.md` = rebuild/overwrite remote (DANGEROUS, this device → remote); `redflag3.md` = fetch from remote (safe) — but redflag3 is unreliable on these Android devices.
