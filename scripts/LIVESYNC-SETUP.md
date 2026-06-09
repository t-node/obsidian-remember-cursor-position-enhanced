# LiveSync + RCP-E — end-to-end (4 devices)

## Are you thinking about this correctly?

**Yes.** For your goal (fast note + cursor/scroll state across 4 devices):

| Layer | Role |
|-------|------|
| **Self-hosted LiveSync** | Syncs vault files (notes + `cursor-state/*.json`) in ~1–3s while Obsidian is open |
| **RCP-E v2.1+** | Merges per-device state; latest position wins; active device is not yanked backward |

LiveSync + RCP-E is **faster and lower overhead** than Syncthing + RCP-E for cursor state (fewer conflict files, sync while editing).

**Do not run Syncthing and LiveSync on the same vault.**

---

## What you need from yourself (before starting)

1. **Master laptop** — the one with the complete, correct vault (`C:\notes1` or your path).
2. **CouchDB host** — usually the same master laptop (Docker). It must be on when other devices sync.
3. **Tailscale** — free account; install on all 4 devices so Android can reach CouchDB over HTTPS.
4. **E2E passphrase** — one phrase you choose; same on every device (LiveSync encrypts).
5. **Backup** — zip the vault before migrating.

**Realistic time:** first full migration ~1–2 hours. Each extra device after Setup URI exists: ~5 minutes.

---

## Step 0 — Plugin v2.1.0 on master (desktop)

```powershell
cd c:\obsidian-remember-cursor-position
npm test
npm run build
npm run deploy
```

In Obsidian: **Ctrl+R**. Confirm Settings → RCP-E → State folder = `cursor-state`.

Add to **Settings → Files & links → Excluded files:** `cursor-state/`

---

## Step 1 — CouchDB on master laptop

```powershell
cd c:\obsidian-remember-cursor-position\scripts
.\setup-livesync-couchdb.ps1
```

Save the password. Database name: `obsidian-vault`.

---

## Step 2 — Tailscale (all 4 devices)

1. Install [Tailscale](https://tailscale.com/download) on both laptops, phone, tablet.
2. Same account on all.
3. On CouchDB laptop: `tailscale ip -4` → note the `100.x.x.x` address.

---

## Step 3 — Master laptop: LiveSync

1. **Syncthing:** Pause or remove sync for this vault only (not other folders).
2. **Plugins:** Enable **Self-hosted LiveSync** (community).
3. **Connect:**
   - URI: `http://127.0.0.1:5984/obsidian-vault`
   - User: `obsidian`
   - Password: (from step 1)
   - E2E passphrase: (your choice)
4. **Mode:** LiveSync (not periodic).
5. **First sync:** **Overwrite remote with local** (master has truth).
6. Wait until sync finishes.
7. **Copy setup URI** from LiveSync settings.

---

## Step 4 — Other laptop, phone, tablet

1. Pause Syncthing for this vault.
2. Install Self-hosted LiveSync + RCP-E (BRAT: `t-node/obsidian-remember-cursor-position-enhanced`).
3. Paste **setup URI** → **Fetch from remote**.
4. Same E2E passphrase when prompted.
5. **Ctrl+R** (or full restart on mobile).
6. Confirm RCP-E state folder = `cursor-state/`.
7. Add `cursor-state/` to excluded files.

---

## Step 5 — Verify (2 minutes)

| Test | Expected |
|------|----------|
| Edit note on phone, open on laptop | Text appears in ~1–3s |
| Scroll to 80% on laptop, open note on phone | Scroll ~80% |
| Scroll on phone while laptop has note open | Laptop does not snap backward |
| Four devices | Each has its own `cursor-state/{deviceId}.json` |

---

## What to send if you want hands-on help

- Which laptop is master + CouchDB host
- Tailscale IP of CouchDB host (`100.x.x.x`)
- Whether Syncthing still has duplicate vault folders on phone
- Any LiveSync error from Obsidian → Help → Show debug info

---

## After verification

- Remove Syncthing folder for this vault on all devices.
- Keep a weekly vault zip backup (sync is not backup).
