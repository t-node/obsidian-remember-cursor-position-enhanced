import json, urllib.request, base64

base = 'http://127.0.0.1:5984/obsidian-vault/_local/obsydian_livesync_milestone'
auth = base64.b64encode(b'obsidian:11111111').decode()

def call(method, data=None):
    r = urllib.request.Request(base, data=data, method=method,
        headers={'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(r, timeout=15))

doc = call('GET')
print('before: locked =', doc.get('locked'), '| accepted_nodes =', doc.get('accepted_nodes'))

# Unlock and accept every known node so no real device is blocked
known = set(doc.get('accepted_nodes', []) or [])
known |= set((doc.get('node_chunk_info', {}) or {}).keys())
known |= set((doc.get('node_info', {}) or {}).keys())
doc['locked'] = False
doc['accepted_nodes'] = sorted(known)

res = call('PUT', json.dumps(doc).encode())
print('PUT ok:', res.get('ok'))

after = call('GET')
print('after:  locked =', after.get('locked'), '| accepted_nodes =', after.get('accepted_nodes'))
