import json, re, sys

p = sys.argv[1]
raw = open(p, encoding='utf-8').read()

bad = re.findall(r'\\(?!["\\/bfnrtu])', raw)
print("bad-escape count:", len(bad))

def repair(s):
    return re.sub(r'\\(["\\/bfnrtu])|\\', lambda m: m.group(0) if m.group(1) else '\\\\', s)

try:
    d = json.loads(raw)
    print("JSON parses as-is: YES")
    needs_fix = False
except Exception as e:
    print("JSON parses as-is: NO ->", e)
    raw = repair(raw)
    d = json.loads(raw)
    print("  repaired to valid JSON")
    needs_fix = True

print("isConfigured:", d.get('isConfigured'))
print("encrypt:", d.get('encrypt'))
print("activeConfigurationId:", d.get('activeConfigurationId'))
print("remoteConfigurations:", list(d.get('remoteConfigurations', {}).keys()))
print("useHistory:", d.get('useHistory'), "| skipOlderFilesOnSync:", d.get('skipOlderFilesOnSync'))
print("syncIgnoreRegEx:", repr(d.get('syncIgnoreRegEx')))
print("deviceAndVaultName:", repr(d.get('deviceAndVaultName')))

if len(sys.argv) > 2 and sys.argv[2] == '--write':
    # Match laptop settings; preserve phone's own connection/device fields
    d['useHistory'] = False
    d['skipOlderFilesOnSync'] = False
    d['automaticallyDeleteMetadataOfDeletedFiles'] = 7
    d['syncIgnoreRegEx'] = r'^rcp-enhanced-logs/|^cursor-state/\.diag-'
    out = sys.argv[3]
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    json.load(open(out, encoding='utf-8'))
    print("[OK] wrote patched+validated phone config ->", out)
