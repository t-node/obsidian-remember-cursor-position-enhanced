# Syncthing Migration Plan — replace LiveSync

**Goal:** one sync engine (Syncthing) for the whole vault *including* `cursor-state/`. Retire
CouchDB + WSL + the bridge + LiveSync. The RCP-E plugin **stays** — it only reads/writes
`cursor-state/{deviceId}.json`, which is sync-agnostic and single-writer (conflict-free), so
Syncthing carries it fine.

**Why:** removes the entire class of recent pain (WSL-not-starting, relay 502s, lock/rebuild,
chunk bloat). Syncthing does direct file transfer — faster for bulk, no database, no WSL.

---

## ⚑ FINAL STATE (2026-06-23) — how it actually ended up (overrides bits of the plan below)

- **NO Tailscale.** Uses Syncthing's **native networking**: local discovery + global discovery +
  relays all ON, device addresses = `dynamic`. At home, devices connect directly over LAN
  (tablet seen at `192.168.29.68:22000`); away, global discovery + encrypted relays.
- **Hub pinned to Syncthing v2.0.11** (`--allow-newer-config`, auto-upgrade OFF) — v2.1.x has a
  zero-byte-file bug (#10709) that breaks the connection. Watchdog task `ObsidianSyncthing`.
- **Hub fsWatcherDelayS = 1s** for snappy auto-sync. Manual force = `FORCE-SYNC.cmd` →
  `scripts/sync-now.ps1` (rescans hub + taps RESCAN ALL on ADB devices), or each device's
  built-in **RESCAN ALL** button.
- **CRITICAL — the device-ID trap (cursor sync):** RCP-E stores its per-device ID in
  `.obsidian/plugins/remember-cursor-position-enhanced/.device-id.local.json`. Syncthing syncing
  `.obsidian` copied the laptop's ID onto the tablet → both became `vyovb870` → they fought over
  one cursor file and cursor-position sync broke. **Fix: that file MUST be in the ignore list**
  (it now is), and each device needs its own ID (tablet restored to `bri9e1q4`). The plugin even
  defines `STIGNORE_LOCAL_RULES` for exactly this. Don't forget it when adding the phone / 2nd laptop.
- **`.stignore` (set on every device):** `*.sync-conflict-*`, `.obsidian/workspace*`,
  `.obsidian/**/*.log`, **`.obsidian/plugins/remember-cursor-position-enhanced/.device-id.local.json`**,
  `rcp-enhanced-logs`, `sync-health`, `.trash`, livesync `data.json`.
- **Done:** laptop + tablet (bidirectional, content + cursor-state verified). **Pending:** phone
  (USB once to enable wireless ADB), 2nd laptop, then retire LiveSync (disable plugin + the
  CouchDB/bridge/backup tasks).

---

## Topology
- **Hub = master laptop** `desktop-vvtrbng` (100.119.250.2) — always on.
- Peers: `bng1122584x5t3` 2nd laptop (100.80.31.101), `vevins-s25` phone (100.96.229.92),
  `vevins-tab-a9` tablet (100.93.19.49).
- Connect over **Tailscale static addresses** (`tcp://100.x.x.x:22000`) — reliable, no relays/
  discovery needed. One shared **Folder ID**; the local path differs per device.

| device | local vault path |
|---|---|
| master laptop | `C:\notes1` |
| 2nd laptop | (verify its vault path) |
| tablet | `/storage/emulated/0/ObsidianVault` |
| phone | `/storage/emulated/0/Documents/Test` (verify) |

---

## Safety first
- **Back up** `C:\notes1` (zip) before starting; keep the latest CouchDB backup (already in
  `C:\notes1-couchdb-backups`) for rollback.
- **Never let LiveSync and Syncthing replicate the same files at once.** We seed with Syncthing
  while LiveSync is *suspended*, verify, then remove LiveSync.

---

## Robustness hardening (robust > fast — the whole point)
These are what make Syncthing *trustworthy*, not just working. All are baked into the phases below.

1. **File versioning on every device (Staggered).** Every change keeps old versions
   (`.stversions/`) — 1h granularity for a day, daily for 30 days. This is a time-machine: any
   accidental delete, bad overwrite, or conflict is recoverable on the spot. Single most important
   robustness feature. (Costs disk; that's the trade for robust.)
2. **Tailscale-only networking.** Disable Syncthing **global discovery** and **relaying**; pin each
   device by **static Tailscale address** `tcp://100.x.x.x:22000`. No dependence on external
   discovery/relay servers, fully private, deterministic — it works iff Tailscale is up (which it
   already must be).
3. **Hub always running.** Run Syncthing on the master laptop via a **logon scheduled task with
   auto-restart** (same pattern that now keeps WSL/CouchDB up). The hub is the canonical copy that's
   always reachable, so any device converges the moment it comes online — no "both peers must be up".
4. **Independent daily snapshot.** A scheduled **zip (or local git) backup of `C:\notes1`** that is
   *not* part of Syncthing. If sync ever does something wrong, this is an out-of-band copy Syncthing
   can't touch. (Reuses the backup-task pattern we already built.)
5. **Health monitor + conflict scan.** Extend the existing 30-min health logger to record each
   folder's completion %, last-seen-per-device, and **alert on any `*.sync-conflict-*` file**, so a
   problem surfaces immediately instead of silently.
6. **Android = persistent foreground service.** Syncthing-Fork set to "always run in background" +
   **battery-optimization exemption** + run while charging. On Samsung (aggressive killer) this is
   essential; worst case it's "syncs when you open the app," never data loss.
7. **Receive-Only seed** (Phase 2) so the hub's truth can never be polluted by a stale peer.

---

## Phase 0 — clean baseline (in progress)
Let the **tablet's current LiveSync Fetch finish** (tablet vault == master). Then Syncthing has
nothing to transfer to the tablet — it just indexes and matches. (Watcher is tracking this.)

## Phase 1 — Master hub
1. Launch Syncthing (already at `AppData\Local\Syncthing`); register a **logon scheduled task with
   auto-restart** so it's always running (robustness #3).
2. Add folder `C:\notes1` → note the **Folder ID**. Set **Send Only** for the seed.
3. Enable **Staggered file versioning** on the folder (robustness #1).
4. Apply `.stignore` (below). GUI bound to `127.0.0.1` only.
5. Settings → Connections: **uncheck** global discovery + relaying; rely on Tailscale (robustness #2).
6. Register the **daily vault-snapshot** task (robustness #4).

## Phase 2 — each peer (seed as master-truth)
For every peer: install/enable Syncthing (Android = **Syncthing-Fork** from F-Droid +
battery-optimisation exemption), pair device IDs with the hub, add the **same Folder ID** at the
device's vault path, set the folder **Receive Only** for the seed.
- **Tablet:** already matches master (Phase 0) → instant.
- **Phone:** has the *old* vault. Receive-Only means master's state (incl. deletions) wins; the
  phone's stale-only files show as "local additions" → use **Revert local changes** so the phone
  matches master exactly. (This is what prevents old files resurrecting onto the hub.)
- **2nd laptop:** same as phone if it's behind.

## Phase 3 — verify, then go two-way
- Edit a note on master → appears on every device within seconds.
- Scroll a note on the tablet, wait, open it on master → it lands at that position (RCP-E +
  cursor-state over Syncthing works).
- No `.sync-conflict-*` files; file counts match.
- **Flip master + all peers to Send & Receive** (needed so each device's own `cursor-state` file
  and edits propagate).

## Phase 4 — retire LiveSync (only after Phase 3 passes)
- Obsidian on each device: **disable** Self-hosted LiveSync (keep RCP-E).
- Master laptop:
  - `docker stop obsidian-livesync-couchdb`
  - **Disable** (don't delete yet) tasks `ObsidianCouchBridge` + `ObsidianCouchBackup`.
  - `netsh interface portproxy delete v4tov4 listenport=5994 listenaddress=127.0.0.1`
  - `tailscale serve reset`
  - Leave the CouchDB volume + disabled tasks in place for a ~2-week rollback grace period, then
    delete. Auto-login: keep or revert (your call).

## `.stignore` (on the hub; syncs to peers)
```
// device-specific Obsidian state (would churn/conflict)
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/plugins/obsidian-livesync/data.json
// transient
rcp-enhanced-logs/
.trash/
// NOTE: cursor-state/ is intentionally NOT ignored — we want it synced.
```

## Rollback
Re-enable the LiveSync plugin + re-enable the two scheduled tasks (CouchDB volume is intact),
stop Syncthing. Back to today's state.

## What I can/can't automate
- **Laptops + Tailscale wiring + .stignore + LiveSync teardown:** I can do via CLI.
- **Android (Syncthing-Fork install, storage permission, battery exemption, first pairing):**
  needs taps on the device — I can drive a lot via ADB, but you may need to approve a couple of
  Android permission prompts.
