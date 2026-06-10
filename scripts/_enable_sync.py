import json, re, sys

p = sys.argv[1]
write = len(sys.argv) > 2 and sys.argv[2] == '--write'
out = sys.argv[3] if write else None

raw = open(p, encoding='utf-8').read()

def repair(s):
    return re.sub(r'\\(["\\/bfnrtu])|\\', lambda m: m.group(0) if m.group(1) else '\\\\', s)

try:
    d = json.loads(raw)
except Exception:
    d = json.loads(repair(raw))

# Settings that make cross-device sync actually flow + give us logs
desired = {
    'liveSync': True,                 # continuous real-time replication both ways (~1-3s)
    'syncOnStart': True,              # pull on launch so you open at latest
    'useHistory': False,             # stop CouchDB re-bloat
    'skipOlderFilesOnSync': False,   # never skip an incoming cursor-state update
    'automaticallyDeleteMetadataOfDeletedFiles': 7,
    'showVerboseLog': True,          # detailed log
    'writeLogToTheFile': True,       # persist log to a file we can read/pull
    'syncIgnoreRegEx': r'^rcp-enhanced-logs/|^cursor-state/\.diag-',
}
print(f"--- {p} ---")
for k, v in desired.items():
    print(f"  {k}: {d.get(k)!r} -> {v!r}")
    d[k] = v
print(f"  (preserved) isConfigured={d.get('isConfigured')} encrypt={d.get('encrypt')} activeConfig={d.get('activeConfigurationId')}")

if write:
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    json.load(open(out, encoding='utf-8'))
    print(f"[OK] wrote + validated -> {out}")
