import json, sys

p = sys.argv[1]
write = len(sys.argv) > 2 and sys.argv[2] == '--write'
out = sys.argv[3] if write else None

d = json.load(open(p, encoding='utf-8'))

desired = {
    'debugLogging': False,     # stop verbose debug
    'logToFile': False,        # stop writing rcp-enhanced-logs/*.log every ~2s (the flood)
    'saveDebounceMs': 1500,    # coalesce rapid scroll saves (was 200 -> 5 writes/10s)
    'reloadOnExternalChange': True,    # keep: pick up peer device changes
    'aggressiveCrossDeviceSync': True, # keep: cross-device merge
}
print(f"--- {p} ---")
for k, v in desired.items():
    print(f"  {k}: {d.get(k)!r} -> {v!r}")
    d[k] = v

if write:
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    json.load(open(out, encoding='utf-8'))
    print(f"[OK] wrote + validated -> {out}")
