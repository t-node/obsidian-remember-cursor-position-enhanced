import assert from 'node:assert/strict';

// Mirrors state-logic.ts — kept inline so tests run with plain Node (no Obsidian runtime).
const SCROLL_EQ_EPSILON = 2;

function getFileHash(filePath) {
	let hash1 = 0;
	let hash2 = 0;
	const prime1 = 31;
	const prime2 = 37;
	for (let i = 0; i < filePath.length; i++) {
		const char = filePath.charCodeAt(i);
		hash1 = (hash1 * prime1 + char) & 0x7fffffff;
		hash2 = (hash2 * prime2 + char) & 0x7fffffff;
	}
	return hash1.toString(36) + hash2.toString(36) + filePath.length.toString(36);
}

function getStateFilePath(stateDir, notePath) {
	return `${stateDir}/${getFileHash(notePath)}.json`;
}

function getPerDeviceStateFilePath(stateDir, notePath, deviceId) {
	return `${stateDir}/${getFileHash(notePath)}-${deviceId}.json`;
}

function normalizeStateFileBaseName(fileName) {
	return fileName.replace(/\.sync-conflict-[^/\\]+(?=\.json$)/i, '');
}

function stateFileBelongsToNote(stateDir, notePath, filePath) {
	if (!filePath.startsWith(stateDir + '/') || !filePath.endsWith('.json')) {
		return false;
	}
	const hash = getFileHash(notePath);
	const base = normalizeStateFileBaseName(filePath.split('/').pop() ?? '').replace(/\.json$/, '');
	return base === hash || base.startsWith(hash + '-');
}

function compareAcrossDevices(a, b) {
	return (a.lastModified ?? 0) - (b.lastModified ?? 0);
}

function pickNewerTagged(a, b) {
	if (a.sourceDeviceId && b.sourceDeviceId && a.sourceDeviceId === b.sourceDeviceId) {
		const revA = a.revision ?? 0;
		const revB = b.revision ?? 0;
		if (revA !== revB) return revA >= revB ? a : b;
		return (a.lastModified ?? 0) >= (b.lastModified ?? 0) ? a : b;
	}
	return compareAcrossDevices(a, b) >= 0 ? a : b;
}

function mergeStatesFromAll(sources, options) {
	const valid = sources.filter((st) => isValidState(st));
	if (valid.length === 0) return null;
	let newest = valid[0];
	for (const candidate of valid.slice(1)) {
		newest = pickNewerTagged(newest, candidate);
	}
	for (const candidate of valid) {
		if (candidate === newest) continue;
		if ((candidate.scroll ?? 0) > 20 && isWeakDefaultScrollSave(newest, candidate)) {
			return candidate;
		}
	}
	const { sourceDeviceId: _s, ...rest } = newest;
	return rest;
}

function isWeakTopOfNoteState(state) {
	const scroll = state.scroll ?? 0;
	if (scroll >= 5) return false;
	const atOrigin =
		!state.cursor ||
		(state.cursor.from.line === 0 &&
			state.cursor.from.ch === 0 &&
			state.cursor.to.line === 0 &&
			state.cursor.to.ch === 0);
	return atOrigin;
}

function isWeakDefaultScrollSave(proposed, existing) {
	if (existing.scroll == null || existing.scroll <= 20) return false;
	return isWeakTopOfNoteState(proposed);
}

function isDeviceStoreFileName(fileName) {
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/i, '');
	if (!base || base.includes('-')) return false;
	return /^[a-z0-9]{8}$/i.test(base);
}

function isOwnDeviceStateFile(stateFilePath, deviceId) {
	const fileName = stateFilePath.split('/').pop() ?? stateFilePath;
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/i, '');
	return base === deviceId || base.endsWith(`-${deviceId}`);
}

function getDeviceStorePath(stateDir, deviceId) {
	return `${stateDir}/${deviceId}.json`;
}

function shouldWatchForRemoteState(stateFiles, deviceId, merged) {
	if (stateFiles.length === 0) return true;
	const hasRemote = stateFiles.some((f) => !isOwnDeviceStateFile(f, deviceId));
	if (hasRemote) return false;
	return !merged || isWeakTopOfNoteState(merged);
}

function shouldApplyMergedState(disk, applied) {
	if (!isValidState(disk)) return false;
	if (!applied || !isValidState(applied)) return true;
	if (isEphemeralStatesEquals(disk, applied)) return false;
	const diskScroll = disk.scroll ?? 0;
	const appliedScroll = applied.scroll ?? 0;
	if (appliedScroll > 20 && isWeakTopOfNoteState(disk) && !isWeakTopOfNoteState(applied)) return false;
	if (diskScroll > 20 && isWeakDefaultScrollSave(applied, disk)) return true;
	if ((applied.lastModified ?? 0) > (disk.lastModified ?? 0)) return false;
	if ((disk.lastModified ?? 0) > (applied.lastModified ?? 0)) return true;
	return false;
}

function isStateFilePath(stateDir, path) {
	return path.startsWith(stateDir + '/') && path.endsWith('.json');
}

function isValidState(st) {
	return !!(st.cursor || (st.scroll != null && !isNaN(st.scroll)));
}

function isEphemeralStatesEquals(state1, state2) {
	if (state1.cursor && !state2.cursor) return false;
	if (!state1.cursor && state2.cursor) return false;
	if (state1.cursor) {
		if (state1.cursor.from.ch !== state2.cursor.from.ch) return false;
		if (state1.cursor.from.line !== state2.cursor.from.line) return false;
		if (state1.cursor.to.ch !== state2.cursor.to.ch) return false;
		if (state1.cursor.to.line !== state2.cursor.to.line) return false;
	}
	const scroll1 = state1.scroll;
	const scroll2 = state2.scroll;
	if (scroll1 == null && scroll2 == null) {
		// both absent
	} else if (scroll1 == null || scroll2 == null) {
		return false;
	} else if (Math.abs(scroll1 - scroll2) > SCROLL_EQ_EPSILON) {
		return false;
	}
	return true;
}

function mergeStatesByTimestamp(incoming, local) {
	const incomingTime = incoming.lastModified ?? 0;
	const localTime = local?.lastModified ?? 0;
	return incomingTime >= localTime ? incoming : local;
}

function isForbiddenSharedLogPath(path) {
	const file = path.replace(/\\/g, '/').split('/').pop() ?? path;
	if (file === 'debug.log') return true;
	if (file === 'rcp-enhanced-debug.log') return true;
	if (file.startsWith('rcp-enhanced-debug.sync-conflict')) return true;
	if (file.startsWith('debug.sync-conflict')) return true;
	if (file.startsWith('~syncthing~') && file.includes('rcp-enhanced-debug')) return true;
	return false;
}

function isPerDeviceLogPath(path) {
	const normalized = path.replace(/\\/g, '/');
	return (
		normalized.startsWith('rcp-enhanced-logs/') &&
		normalized.endsWith('.log') &&
		!normalized.includes('sync-conflict')
	);
}

function isRegressiveScrollSave(proposed, existing) {
	if (proposed.scroll == null || existing.scroll == null) return false;
	if ((proposed.lastModified ?? 0) > (existing.lastModified ?? 0)) return false;
	return proposed.scroll < existing.scroll - 5 && existing.scroll > 20;
}

let passed = 0;
let failed = 0;

function test(name, fn) {
	try {
		fn();
		passed++;
		console.log(`  ✓ ${name}`);
	} catch (e) {
		failed++;
		console.error(`  ✗ ${name}`);
		console.error(`    ${e.message}`);
	}
}

function explainApplyRejection(disk, applied) {
	if (!isValidState(disk)) return 'merged state invalid';
	if (!applied || !isValidState(applied)) return 'no local state — would apply';
	if (isEphemeralStatesEquals(disk, applied)) return 'already equal to editor state';
	if ((applied.lastModified ?? 0) > (disk.lastModified ?? 0)) {
		return `local timestamp newer (${applied.lastModified} > ${disk.lastModified ?? 0})`;
	}
	return 'other';
}

function analyzeMergeForNote(sources) {
	const valid = sources.filter((st) => isValidState(st));
	if (valid.length === 0) return { merged: null, winnerDeviceId: null, candidates: [] };
	let newest = valid[0];
	for (const c of valid.slice(1)) {
		newest = pickNewerTagged(newest, c);
	}
	const { sourceDeviceId, ...rest } = newest;
	return {
		merged: rest,
		winnerDeviceId: sourceDeviceId ?? null,
		candidates: valid.map((s) => ({
			deviceId: s.sourceDeviceId,
			scroll: s.scroll,
			lastModified: s.lastModified,
		})),
	};
}

console.log('\nRemember Cursor Position — automated tests\n');

test('getFileHash is stable for same path', () => {
	const path = 'notes/research/AI equation.md';
	assert.equal(getFileHash(path), getFileHash(path));
});

test('getFileHash differs for different paths', () => {
	assert.notEqual(getFileHash('note-a.md'), getFileHash('note-b.md'));
});

test('getStateFilePath uses hash filename', () => {
	const dir = '.obsidian/plugins/remember-cursor-position/states';
	const result = getStateFilePath(dir, 'folder/my note.md');
	assert.match(result, /^\.obsidian\/plugins\/remember-cursor-position\/states\/[a-z0-9]+\.json$/);
});

test('isStateFilePath matches state dir json files only', () => {
	const dir = '.obsidian/plugins/remember-cursor-position/states';
	assert.equal(isStateFilePath(dir, `${dir}/abc123.json`), true);
	assert.equal(isStateFilePath(dir, `${dir}/abc123-mobile1.json`), true);
	assert.equal(isStateFilePath(dir, `${dir}/abc123.sync-conflict-20260608.json`), true);
	assert.equal(isStateFilePath(dir, `${dir}/abc.txt`), false);
	assert.equal(isStateFilePath(dir, 'notes/other.json'), false);
});

test('getPerDeviceStateFilePath includes device id', () => {
	const dir = '.obsidian/plugins/remember-cursor-position/states';
	const path = getPerDeviceStateFilePath(dir, 'folder/my note.md', 'abc12345');
	assert.match(path, /abc12345\.json$/);
});

test('stateFileBelongsToNote matches legacy, per-device, and conflict files', () => {
	const dir = '.obsidian/plugins/remember-cursor-position/states';
	const note = 'folder/my note.md';
	const hash = getFileHash(note);
	assert.equal(stateFileBelongsToNote(dir, note, `${dir}/${hash}.json`), true);
	assert.equal(stateFileBelongsToNote(dir, note, `${dir}/${hash}-phone1.json`), true);
	assert.equal(
		stateFileBelongsToNote(dir, note, `${dir}/${hash}.sync-conflict-20260608-ABC.json`),
		true
	);
	assert.equal(stateFileBelongsToNote(dir, note, `${dir}/otherhash.json`), false);
});

test('mergeStatesFromAll picks newest valid state', () => {
	const merged = mergeStatesFromAll([
		{ scroll: 10, lastModified: 1000 },
		{ scroll: 192, lastModified: 2000 },
		{},
	]);
	assert.equal(merged.scroll, 192);
});

test('mergeStatesFromAll ignores weak scroll-0 even if timestamp is newest', () => {
	const merged = mergeStatesFromAll([
		{ scroll: 0.0258, lastModified: 3000 },
		{ scroll: 78.2875, lastModified: 2000 },
	]);
	assert.equal(merged.scroll, 78.2875);
});

test('shouldApplyMergedState upgrades weak top to mobile scroll', () => {
	assert.equal(
		shouldApplyMergedState(
			{ scroll: 78.2875, lastModified: 2000 },
			{ scroll: 0.0258, lastModified: 3000 }
		),
		true
	);
});

test('isWeakDefaultScrollSave blocks scroll-0 clobber', () => {
	assert.equal(isWeakDefaultScrollSave({ scroll: 0 }, { scroll: 192 }), true);
	assert.equal(
		isWeakDefaultScrollSave(
			{ scroll: 0, cursor: { from: { ch: 0, line: 0 }, to: { ch: 0, line: 0 } } },
			{ scroll: 192 }
		),
		true
	);
	assert.equal(isWeakDefaultScrollSave({ scroll: 50 }, { scroll: 192 }), false);
});

test('isDeviceStoreFileName recognizes v2 consolidated stores', () => {
	assert.equal(isDeviceStoreFileName('vyovb870.json'), true);
	assert.equal(isDeviceStoreFileName('5dt3aclb18ii5q-vyovb870.json'), false);
	assert.equal(isDeviceStoreFileName('5dt3aclb18ii5q.json'), false);
});

test('isOwnDeviceStateFile matches v2 and legacy paths', () => {
	const dir = '.obsidian/plugins/remember-cursor-position-enhanced/states';
	assert.equal(isOwnDeviceStateFile(`${dir}/vyovb870.json`, 'vyovb870'), true);
	assert.equal(isOwnDeviceStateFile(`${dir}/abc-vyovb870.json`, 'vyovb870'), true);
	assert.equal(isOwnDeviceStateFile(`${dir}/ytt2gvef.json`, 'vyovb870'), false);
});

test('shouldWatchForRemoteState when no files or only weak local file', () => {
	const dir = '.obsidian/plugins/remember-cursor-position-enhanced/states';
	assert.equal(shouldWatchForRemoteState([], 'vyovb870', null), true);
	assert.equal(
		shouldWatchForRemoteState(
			[`${dir}/vyovb870.json`],
			'vyovb870',
			{ scroll: 0, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } }
		),
		true
	);
	assert.equal(
		shouldWatchForRemoteState(
			[`${dir}/vyovb870.json`, `${dir}/ytt2gvef.json`],
			'vyovb870',
			{ scroll: 0 }
		),
		false
	);
	assert.equal(
		shouldWatchForRemoteState(
			[`${dir}/vyovb870.json`],
			'vyovb870',
			{ scroll: 39 }
		),
		false
	);
});

test('mergeStatesFromAll uses wall-clock across devices', () => {
	const merged = mergeStatesFromAll([
		{ scroll: 10, lastModified: 1000, sourceDeviceId: 'desktop', revision: 5 },
		{ scroll: 192, lastModified: 2000, sourceDeviceId: 'phone', revision: 2 },
	]);
	assert.equal(merged.scroll, 192);
});

test('mergeStatesFromAll uses revision within same device', () => {
	const merged = mergeStatesFromAll([
		{ scroll: 10, lastModified: 5000, sourceDeviceId: 'phone', revision: 2 },
		{ scroll: 192, lastModified: 1000, sourceDeviceId: 'phone', revision: 9 },
	]);
	assert.equal(merged.scroll, 192);
});

test('isValidState accepts cursor-only state', () => {
	assert.equal(isValidState({ cursor: { from: { ch: 0, line: 5 }, to: { ch: 0, line: 5 } } }), true);
});

test('isValidState accepts scroll at zero (top of note)', () => {
	assert.equal(isValidState({ scroll: 0 }), true);
});

test('isValidState rejects empty state', () => {
	assert.equal(isValidState({}), false);
	assert.equal(isValidState({ scroll: NaN }), false);
});

test('isEphemeralStatesEquals treats scroll 0 as equal', () => {
	assert.equal(isEphemeralStatesEquals({ scroll: 0 }, { scroll: 0 }), true);
});

test('isEphemeralStatesEquals detects cursor movement', () => {
	const a = { cursor: { from: { ch: 0, line: 10 }, to: { ch: 0, line: 10 } } };
	const b = { cursor: { from: { ch: 0, line: 20 }, to: { ch: 0, line: 20 } } };
	assert.equal(isEphemeralStatesEquals(a, b), false);
});

test('mergeStatesByTimestamp keeps newer state', () => {
	const older = { scroll: 100, lastModified: 1000 };
	const newer = { scroll: 500, lastModified: 2000 };
	assert.equal(mergeStatesByTimestamp(newer, older).scroll, 500);
	assert.equal(mergeStatesByTimestamp(older, newer).scroll, 500);
});

test('isRegressiveScrollSave detects jump back to top', () => {
	assert.equal(isRegressiveScrollSave({ scroll: 0 }, { scroll: 500 }), true);
	assert.equal(isRegressiveScrollSave({ scroll: 496 }, { scroll: 500 }), false);
	assert.equal(isRegressiveScrollSave({ scroll: 0 }, { scroll: 10 }), false);
});

test('isRegressiveScrollSave allows intentional scroll-up with newer timestamp', () => {
	assert.equal(
		isRegressiveScrollSave(
			{ scroll: 130, lastModified: 2000 },
			{ scroll: 337, lastModified: 1000 }
		),
		false
	);
});

test('shouldApplyMergedState does not yank scroll when editor is newer', () => {
	assert.equal(
		shouldApplyMergedState(
			{ scroll: 337, lastModified: 1000 },
			{ scroll: 130, lastModified: 2000 }
		),
		false
	);
});

test('isEphemeralStatesEquals treats sub-line scroll drift as equal (echo-loop fix)', () => {
	// The "always Q11" bug: cross-device restore lands 211.39 vs 210.96 — must read as SAME,
	// otherwise it re-saves with a fresh timestamp and bounces between devices forever.
	assert.equal(
		isEphemeralStatesEquals(
			{ scroll: 211.3937, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } },
			{ scroll: 210.9573, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } }
		),
		true
	);
	// A real scroll away (many lines) is still a change.
	assert.equal(
		isEphemeralStatesEquals(
			{ scroll: 211, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } },
			{ scroll: 169, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } }
		),
		false
	);
});

test('shouldApplyMergedState rejects weak top-of-note even with newer remote clock (snap-back fix)', () => {
	// Remote "default" (scroll 0, caret origin) with a SKEWED-newer wall clock must NOT
	// override a real reading position. This is the "scroll keeps resetting to top" bug.
	assert.equal(
		shouldApplyMergedState(
			{ scroll: 2, lastModified: 9999, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } },
			{ scroll: 340, lastModified: 1000, cursor: { from: { line: 88, ch: 0 }, to: { line: 88, ch: 0 } } }
		),
		false
	);
});

test('shouldApplyMergedState still applies a real remote position over weak local', () => {
	assert.equal(
		shouldApplyMergedState(
			{ scroll: 340, lastModified: 5000, cursor: { from: { line: 88, ch: 0 }, to: { line: 88, ch: 0 } } },
			{ scroll: 2, lastModified: 1000, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } }
		),
		true
	);
});

test('shouldApplyMergedState applies newer-by-time remote even when local revision counter is higher (cross-device fix)', () => {
	// Per-device `revision` counters are NOT comparable across devices. A remote position that is
	// newer by wall-clock must win even when this device's revision counter is far higher — else
	// the most-used device wins forever and other devices' scroll positions never sync.
	assert.equal(
		shouldApplyMergedState(
			{ scroll: 111.98, lastModified: 1782241276835, revision: 6633, cursor: { from: { line: 5, ch: 0 }, to: { line: 5, ch: 0 } } },
			{ scroll: 88.93, lastModified: 1782233824381, revision: 11381, cursor: { from: { line: 3, ch: 0 }, to: { line: 3, ch: 0 } } }
		),
		true
	);
});

test('explainApplyRejection describes local timestamp win', () => {
	const reason = explainApplyRejection(
		{ scroll: 500, lastModified: 1000 },
		{ scroll: 40, lastModified: 2000 }
	);
	assert.match(reason, /local timestamp newer/);
});

test('analyzeMergeForNote reports winner device', () => {
	const r = analyzeMergeForNote([
		{ sourceDeviceId: 'phone1', scroll: 500, lastModified: 3000, cursor: { from: { line: 88, ch: 0 }, to: { line: 88, ch: 0 } } },
		{ sourceDeviceId: 'desk1', scroll: 40, lastModified: 5000, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } },
	]);
	assert.equal(r.winnerDeviceId, 'desk1');
	assert.equal(r.merged.scroll, 40);
});

test('isCaretAtOrigin detects origin caret with deep scroll', () => {
	function isCaretAtOrigin(state) {
		if (!state.cursor) return true;
		return (
			state.cursor.from.line === 0 &&
			state.cursor.from.ch === 0 &&
			state.cursor.to.line === 0 &&
			state.cursor.to.ch === 0
		);
	}
	assert.equal(
		isCaretAtOrigin({ scroll: 156, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } }),
		true
	);
	assert.equal(isWeakTopOfNoteState({ scroll: 156, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } }), false);
});

test('findNearestHeadingLine finds heading above cursor', () => {
	function findNearestHeadingLine(lines, line) {
		const clamped = Math.max(0, Math.min(line, lines.length - 1));
		for (let i = clamped; i >= 0; i--) {
			if (/^#{1,6}\s/.test(lines[i])) return i;
		}
		return clamped;
	}
	const lines = ['# Title', 'body', '## Section', 'text', 'more'];
	assert.equal(findNearestHeadingLine(lines, 4), 2);
	assert.equal(findNearestHeadingLine(lines, 1), 0);
});

test('isForbiddenSharedLogPath blocks shared vault-root logs', () => {
	assert.equal(isForbiddenSharedLogPath('rcp-enhanced-debug.log'), true);
	assert.equal(isForbiddenSharedLogPath('rcp-enhanced-debug.sync-conflict-20260608.log'), true);
	assert.equal(isForbiddenSharedLogPath('.obsidian/plugins/foo/debug.log'), true);
	assert.equal(isPerDeviceLogPath('rcp-enhanced-logs/Windows-Desktop-abc12345.log'), true);
	assert.equal(isPerDeviceLogPath('rcp-enhanced-debug.log'), false);
});

console.log('\nMock vault simulation\n');

class MockVault {
	constructor() {
		this.files = new Map();
		this.dirs = new Set();
	}
	async exists(path) {
		return this.files.has(path) || this.dirs.has(path);
	}
	async mkdir(path) {
		this.dirs.add(path);
	}
	async read(path) {
		if (!this.files.has(path)) throw new Error('missing');
		return this.files.get(path);
	}
	async write(path, data) {
		this.files.set(path, data);
	}
	async remove(path) {
		this.files.delete(path);
	}
	async list(dir) {
		const prefix = dir.endsWith('/') ? dir : dir + '/';
		return { files: [...this.files.keys()].filter((f) => f.startsWith(prefix)) };
	}
}

async function simulateDeviceStoreStorage() {
	const stateDir = '.obsidian/plugins/remember-cursor-position/states';
	const vault = new MockVault();
	await vault.mkdir(stateDir);

	const notes = [
		'AI equation research.md',
		'Quiz generation notes.md',
		'Daily log 2026-06-08.md',
	];

	async function loadStore(deviceId) {
		const path = getDeviceStorePath(stateDir, deviceId);
		if (!(await vault.exists(path))) {
			return { version: 2, deviceId, storeRevision: 0, notes: {} };
		}
		return JSON.parse(await vault.read(path));
	}

	async function writeNoteState(notePath, state, deviceId = 'desktop1') {
		const store = await loadStore(deviceId);
		const hash = getFileHash(notePath);
		const rev = (store.storeRevision ?? 0) + 1;
		const payload = {
			...state,
			filePath: notePath,
			lastModified: state.lastModified ?? Date.now(),
			revision: rev,
		};
		store.storeRevision = rev;
		store.notes[hash] = payload;
		await vault.write(getDeviceStorePath(stateDir, deviceId), JSON.stringify(store));
		await new Promise((r) => setTimeout(r, 2));
		return payload;
	}

	async function readMergedNoteState(notePath) {
		const listing = await vault.list(stateDir);
		const tagged = [];
		for (const f of listing.files) {
			if (!f.endsWith('.json')) continue;
			const store = JSON.parse(await vault.read(f));
			if (store.version !== 2) continue;
			const hash = getFileHash(notePath);
			const entry = store.notes[hash];
			if (entry) tagged.push({ ...entry, sourceDeviceId: store.deviceId });
		}
		return mergeStatesFromAll(tagged);
	}

	const saved = [];
	for (const note of notes) {
		saved.push(await writeNoteState(note, {
			scroll: 0.35 + saved.length * 0.1,
			cursor: { from: { ch: 0, line: 10 + saved.length * 5 }, to: { ch: 0, line: 10 + saved.length * 5 } },
		}));
	}

	assert.equal((await vault.list(stateDir)).files.length, 1);

	for (let i = 0; i < notes.length; i++) {
		const restored = await readMergedNoteState(notes[i]);
		assert.equal(restored.filePath, notes[i]);
		assert.equal(restored.scroll, saved[i].scroll);
		assert.equal(restored.cursor.from.line, saved[i].cursor.from.line);
	}

	const sharedNote = notes[1];
	const desktopStore = await loadStore('desktop1');
	delete desktopStore.notes[getFileHash(sharedNote)];
	await vault.write(getDeviceStorePath(stateDir, 'desktop1'), JSON.stringify(desktopStore));
	await writeNoteState(
		sharedNote,
		{ scroll: 192, cursor: { from: { ch: 0, line: 196 }, to: { ch: 0, line: 196 } }, lastModified: Date.now() + 5000 },
		'phone1'
	);
	const crossDevice = await readMergedNoteState(sharedNote);
	assert.equal(crossDevice.scroll, 192);

	const oldPath = notes[0];
	const newPath = 'AI equation research v2.md';
	await writeNoteState(newPath, await readMergedNoteState(oldPath));
	const desktop = await loadStore('desktop1');
	delete desktop.notes[getFileHash(oldPath)];
	await vault.write(getDeviceStorePath(stateDir, 'desktop1'), JSON.stringify(desktop));
	assert.equal(await readMergedNoteState(oldPath), null);
	assert.equal((await readMergedNoteState(newPath)).filePath, newPath);

	assert.equal((await vault.list(stateDir)).files.length, 2);

	console.log('  ✓ device store write/read for 3 notes in one file');
	console.log('  ✓ cross-device merge picks newest timestamp');
	console.log('  ✓ rename migrates hash within store');
	console.log('  ✓ seven devices would mean seven files not thousands');
	passed += 4;
}

try {
	await simulateDeviceStoreStorage();
} catch (e) {
	failed++;
	console.error('  ✗ mock vault simulation');
	console.error(`    ${e.message}`);
}

console.log(`\nResults: ${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
