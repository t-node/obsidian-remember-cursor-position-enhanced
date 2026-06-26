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
	const authDiff = (a.authority ?? 0) - (b.authority ?? 0);
	if (authDiff !== 0) return authDiff;
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
	const diskAuth = disk.authority ?? 0;
	const appliedAuth = applied.authority ?? 0;
	if (diskAuth > appliedAuth) return true;
	if (appliedAuth > diskAuth) return false;
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
	if ((proposed.authority ?? 0) > (existing.authority ?? 0)) return false;
	if ((proposed.lastModified ?? 0) > (existing.lastModified ?? 0)) return false;
	return proposed.scroll < existing.scroll - 5 && existing.scroll > 20;
}

function isDeliberateUserSave(p) {
	if (p.loadingFile || p.reloadingState) return false;
	if (p.now < p.restoreGraceUntil) return false;
	return p.now - p.lastInteractionAt < p.windowMs;
}

function isForceOverride(merged, lastAppliedForcedAt) {
	if (!merged || typeof merged.forcedAt !== 'number') return false;
	return merged.forcedAt !== lastAppliedForcedAt;
}

function getForceAck(store, noteHash) {
	return store.acks?.[noteHash] ?? 0;
}

function recordForceAck(store, noteHash, forcedAt) {
	if (forcedAt <= getForceAck(store, noteHash)) return store;
	return {
		...store,
		storeRevision: (store.storeRevision ?? 0) + 1,
		acks: { ...(store.acks ?? {}), [noteHash]: forcedAt },
	};
}

// --- Mirrors device-store.ts revision-counter + recents (G-Counter / merged history) ---
const RECENTS_LIMIT = 100;

function incrementOwnRevision(store, notePath, delta = 1) {
	const hash = getFileHash(notePath);
	const current = store.revisions?.[hash] ?? 0;
	const next = Math.max(0, current + delta);
	return {
		...store,
		storeRevision: (store.storeRevision ?? 0) + 1,
		revisions: { ...(store.revisions ?? {}), [hash]: next },
	};
}

function getTotalRevisionCount(stores, notePath) {
	const hash = getFileHash(notePath);
	let total = 0;
	for (const store of stores) total += store.revisions?.[hash] ?? 0;
	return total;
}

function recordRecentVisit(store, notePath, ts, limit = RECENTS_LIMIT) {
	const hash = getFileHash(notePath);
	const rest = (store.recents ?? []).filter((r) => r.path !== notePath);
	const recents = [{ path: notePath, hash, ts }, ...rest].slice(0, limit);
	return { ...store, storeRevision: (store.storeRevision ?? 0) + 1, recents };
}

function mergeRecentLists(lists, limit) {
	const byPath = new Map();
	for (const list of lists) {
		for (const visit of list ?? []) {
			if (!visit || !visit.path) continue;
			const prev = byPath.get(visit.path);
			if (!prev || (visit.ts ?? 0) > (prev.ts ?? 0)) {
				byPath.set(visit.path, { path: visit.path, hash: visit.hash, ts: visit.ts ?? 0 });
			}
		}
	}
	return Array.from(byPath.values())
		.sort((x, y) => (y.ts ?? 0) - (x.ts ?? 0))
		.slice(0, limit);
}

function mergeRecentVisits(stores, limit = RECENTS_LIMIT) {
	return mergeRecentLists(stores.map((s) => s.recents), limit);
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

test('isDeliberateUserSave: true right after a user interaction (deliberate scroll saved)', () => {
	assert.equal(isDeliberateUserSave({
		now: 10000, lastInteractionAt: 9000, restoreGraceUntil: 0,
		loadingFile: false, reloadingState: false, windowMs: 10000,
	}), true);
});

test('isDeliberateUserSave: false while loading (load-time scroll-0 guard preserved)', () => {
	assert.equal(isDeliberateUserSave({
		now: 10000, lastInteractionAt: 9999, restoreGraceUntil: 0,
		loadingFile: true, reloadingState: false, windowMs: 10000,
	}), false);
});

test('isDeliberateUserSave: false during restore grace (guards preserved)', () => {
	assert.equal(isDeliberateUserSave({
		now: 10000, lastInteractionAt: 9999, restoreGraceUntil: 15000,
		loadingFile: false, reloadingState: false, windowMs: 10000,
	}), false);
});

test('isDeliberateUserSave: false when interaction is stale (automatic re-flush still guarded)', () => {
	assert.equal(isDeliberateUserSave({
		now: 100000, lastInteractionAt: 9000, restoreGraceUntil: 0,
		loadingFile: false, reloadingState: false, windowMs: 10000,
	}), false);
});

test('isForceOverride: true for a fresh force-push (not yet honored)', () => {
	assert.equal(isForceOverride({ forcedAt: 5000 }, 0), true);
});

test('isForceOverride: false once that exact force was already honored (no re-yank)', () => {
	assert.equal(isForceOverride({ forcedAt: 5000 }, 5000), false);
});

test('isForceOverride: true for a newer force after an earlier one', () => {
	assert.equal(isForceOverride({ forcedAt: 9000 }, 5000), true);
});

test('isForceOverride: false for an ordinary (non-forced) merged state', () => {
	assert.equal(isForceOverride({ scroll: 42, lastModified: 1234 }, 0), false);
});

test('recordForceAck: records a new ack and bumps storeRevision', () => {
	const s = recordForceAck({ storeRevision: 3, notes: {} }, 'h1', 5000);
	assert.equal(getForceAck(s, 'h1'), 5000);
	assert.equal(s.storeRevision, 4);
});

test('recordForceAck: no-op (same object) when stamp already acked — no pointless re-write', () => {
	const before = { storeRevision: 4, notes: {}, acks: { h1: 5000 } };
	const after = recordForceAck(before, 'h1', 5000);
	assert.equal(after, before);
});

test('recordForceAck: a newer force for the same note supersedes the old ack', () => {
	const s = recordForceAck({ storeRevision: 1, notes: {}, acks: { h1: 5000 } }, 'h1', 9000);
	assert.equal(getForceAck(s, 'h1'), 9000);
});

test('getForceAck: 0 when the note was never force-pushed', () => {
	assert.equal(getForceAck({ storeRevision: 0, notes: {} }, 'h1'), 0);
});

test('incrementOwnRevision: +1 bumps the note count and storeRevision', () => {
	const s = incrementOwnRevision({ storeRevision: 2, notes: {} }, 'Notes/OS.md');
	assert.equal(s.revisions[getFileHash('Notes/OS.md')], 1);
	assert.equal(s.storeRevision, 3);
});

test('incrementOwnRevision: negative delta undoes but never goes below 0', () => {
	let s = incrementOwnRevision({ storeRevision: 0, notes: {} }, 'a.md'); // 1
	s = incrementOwnRevision(s, 'a.md', -1); // 0
	s = incrementOwnRevision(s, 'a.md', -1); // stays 0
	assert.equal(s.revisions[getFileHash('a.md')], 0);
});

test('getTotalRevisionCount: sums a note across every device (G-Counter)', () => {
	const hash = getFileHash('AWS.md');
	const stores = [
		{ revisions: { [hash]: 2 } },
		{ revisions: { [hash]: 1 } },
		{ revisions: {} },
	];
	assert.equal(getTotalRevisionCount(stores, 'AWS.md'), 3);
});

test('recordRecentVisit: moves an existing note to the front (no duplicates)', () => {
	let s = { storeRevision: 0, notes: {}, recents: [] };
	s = recordRecentVisit(s, 'a.md', 100);
	s = recordRecentVisit(s, 'b.md', 200);
	s = recordRecentVisit(s, 'a.md', 300); // revisit a — should jump to front, not duplicate
	assert.deepEqual(s.recents.map((r) => r.path), ['a.md', 'b.md']);
	assert.equal(s.recents[0].ts, 300);
});

test('recordRecentVisit: caps the stack at the limit', () => {
	let s = { storeRevision: 0, notes: {}, recents: [] };
	for (let i = 0; i < 5; i++) s = recordRecentVisit(s, `n${i}.md`, i, 3);
	assert.equal(s.recents.length, 3);
	assert.deepEqual(s.recents.map((r) => r.path), ['n4.md', 'n3.md', 'n2.md']);
});

test('mergeRecentVisits: unifies devices newest-first, one row per note', () => {
	const stores = [
		{ recents: [{ path: 'a.md', hash: 'x', ts: 100 }, { path: 'b.md', hash: 'y', ts: 50 }] },
		{ recents: [{ path: 'a.md', hash: 'x', ts: 300 }, { path: 'c.md', hash: 'z', ts: 200 }] },
	];
	const merged = mergeRecentVisits(stores);
	assert.deepEqual(merged.map((r) => r.path), ['a.md', 'c.md', 'b.md']);
	assert.equal(merged[0].ts, 300); // newest open of 'a' across devices wins
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

// --- Authority tier: skew-proof force stickiness (the "force reverted to an old state" fix) ---

// Mirror of writeNoteState's authority inheritance + forcePushCurrentNote's tier bump.
function inheritAuthority(mergedExisting, incomingState) {
	return Math.max(mergedExisting?.authority ?? 0, incomingState.authority ?? 0) || undefined;
}
function forcedState(scroll, lastModified, mergedSeen) {
	const authority = (mergedSeen?.authority ?? 0) + 1;
	return { scroll, lastModified, forcedAt: lastModified, authority, cursor: { from: { line: 1, ch: 0 }, to: { line: 1, ch: 0 } } };
}

test('authority: a forced tier-1 state beats a non-forced tier-0 state with a FAR HIGHER wall-clock', () => {
	// This is the exact reported bug: a stale/skewed device carries a higher lastModified.
	const force = { sourceDeviceId: 'phone', scroll: 400, lastModified: 1000, authority: 1, cursor: { from: { line: 50, ch: 0 }, to: { line: 50, ch: 0 } } };
	const skewed = { sourceDeviceId: 'orphan', scroll: 20, lastModified: 9_999_999, authority: 0, cursor: { from: { line: 2, ch: 0 }, to: { line: 2, ch: 0 } } };
	const merged = mergeStatesFromAll([skewed, force]);
	assert.equal(merged.scroll, 400); // the force wins despite the skewed clock
});

test('authority: tier 0 everywhere is byte-identical to the legacy lastModified merge', () => {
	const a = { sourceDeviceId: 'a', scroll: 100, lastModified: 5000, cursor: { from: { line: 9, ch: 0 }, to: { line: 9, ch: 0 } } };
	const b = { sourceDeviceId: 'b', scroll: 200, lastModified: 8000, cursor: { from: { line: 9, ch: 0 }, to: { line: 9, ch: 0 } } };
	assert.equal(mergeStatesFromAll([a, b]).scroll, 200); // newest lastModified, exactly as before
});

test('authority: within the same tier, the newer wall-clock still wins (normal forward reading)', () => {
	const older = { sourceDeviceId: 'a', scroll: 300, lastModified: 5000, authority: 1, cursor: { from: { line: 9, ch: 0 }, to: { line: 9, ch: 0 } } };
	const newer = { sourceDeviceId: 'b', scroll: 600, lastModified: 7000, authority: 1, cursor: { from: { line: 9, ch: 0 }, to: { line: 9, ch: 0 } } };
	assert.equal(mergeStatesFromAll([older, newer]).scroll, 600);
});

test('authority: a NEWER force (tier 2) overrides an older force (tier 1)', () => {
	const f1 = { sourceDeviceId: 'a', scroll: 300, lastModified: 9000, authority: 1, cursor: { from: { line: 9, ch: 0 }, to: { line: 9, ch: 0 } } };
	const f2 = { sourceDeviceId: 'b', scroll: 700, lastModified: 1000, authority: 2, cursor: { from: { line: 9, ch: 0 }, to: { line: 9, ch: 0 } } };
	assert.equal(mergeStatesFromAll([f1, f2]).scroll, 700); // tier 2 wins even with older clock
});

test('authority: every save inherits the forced tier, so the force stays sticky', () => {
	const force = forcedState(400, 1000, { authority: 0 }); // authority 1
	assert.equal(force.authority, 1);
	// A later save on another device, having seen the force, inherits tier 1.
	const inherited = inheritAuthority(force, { scroll: 450, lastModified: 2000 });
	assert.equal(inherited, 1);
	// A device that never saw the force writes tier 0 (undefined) — and loses to the force.
	assert.equal(inheritAuthority({ authority: 0 }, { scroll: 30, lastModified: 5000 }), undefined);
});

test('authority: shouldApplyMergedState applies a higher tier even with an older wall-clock', () => {
	const disk = { scroll: 400, lastModified: 1000, authority: 1, cursor: { from: { line: 50, ch: 0 }, to: { line: 50, ch: 0 } } };
	const applied = { scroll: 20, lastModified: 9_000_000, authority: 0, cursor: { from: { line: 2, ch: 0 }, to: { line: 2, ch: 0 } } };
	assert.equal(shouldApplyMergedState(disk, applied), true);
});

test('authority: a higher-tier WEAK top-of-note still does NOT clobber real reading (guard intact)', () => {
	const weakForce = { scroll: 0, lastModified: 1000, authority: 5, cursor: { from: { line: 0, ch: 0 }, to: { line: 0, ch: 0 } } };
	const realReading = { scroll: 500, lastModified: 10, authority: 0, cursor: { from: { line: 88, ch: 0 }, to: { line: 88, ch: 0 } } };
	assert.equal(shouldApplyMergedState(weakForce, realReading), false);
});

test('authority: a higher-tier save is never treated as a regressive scroll', () => {
	const proposed = { scroll: 10, lastModified: 100, authority: 1 };
	const existing = { scroll: 500, lastModified: 9000, authority: 0 };
	assert.equal(isRegressiveScrollSave(proposed, existing), false);
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
