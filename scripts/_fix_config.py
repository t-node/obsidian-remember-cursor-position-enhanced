import json, re

p = r'C:/notes1/.obsidian/plugins/obsidian-livesync/data.json'
raw = open(p, encoding='utf-8').read()

# Repair invalid JSON string escapes.
# Alternation tries a VALID escape first (consumes backslash + valid char atomically,
# so real \\ pairs and \" \/ \u etc. are preserved), otherwise a lone/bad backslash
# is doubled so it becomes a literal backslash.
valid = set('"\\/bfnrtu')
def repl(m):
    return m.group(0) if m.group(1) else '\\\\'
fixed = re.sub(r'\\(["\\/bfnrtu])|\\', repl, raw)

n_changed = sum(1 for a, b in zip(raw, fixed) if a != b)  # rough indicator
d = json.loads(fixed)
print("[OK] JSON parses. isConfigured:", d['isConfigured'], "| activeConfig:", d['activeConfigurationId'])
print("    remoteConfigurations:", list(d['remoteConfigurations'].keys()))
print("    syncIgnoreRegEx:", repr(d['syncIgnoreRegEx']))
print("    syncInternalFilesIgnorePatterns:", repr(d['syncInternalFilesIgnorePatterns']))

# Patches to curb future bloat
keys = ('useHistory', 'skipOlderFilesOnSync', 'automaticallyDeleteMetadataOfDeletedFiles')
before = {k: d.get(k) for k in keys}
d['useHistory'] = False
d['skipOlderFilesOnSync'] = False
d['automaticallyDeleteMetadataOfDeletedFiles'] = 7
for k in keys:
    print(f"    patch {k}: {before[k]!r} -> {d[k]!r}")

with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
json.load(open(p, encoding='utf-8'))
print("[OK] wrote + round-trip validated data.json")
