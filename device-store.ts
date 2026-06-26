import {
	EphemeralState,
	getFileHash,
	isDeviceStoreFileName,
	isLegacyPerNoteStateFileName,
	isValidState,
	mergeStatesFromAll,
	normalizeStateFileBaseName,
	type TaggedNoteState,
} from './state-logic';

export const DEVICE_STORE_VERSION = 2;

/** Vault-root folder synced by LiveSync (fast path — not under .obsidian). */
export const RECOMMENDED_STATE_DIR = 'cursor-state';

/** How many recently-opened notes each device keeps. The merged cross-device history is also
 *  capped to this. Big enough to cover "the last couple of days" of reading, small enough to stay tiny. */
export const RECENTS_LIMIT = 100;

export interface NoteStateEntry extends EphemeralState {
	/** Monotonic save counter on this device (hybrid clock). */
	revision?: number;
}

/** One entry in a device's recently-opened-notes stack (browser-history style). */
export interface RecentVisit {
	/** Vault path of the note. */
	path: string;
	/** Stable hash of the path (so renames/merges can match cheaply). */
	hash: string;
	/** Last time THIS device opened the note (epoch ms). Newest wins on merge. */
	ts: number;
}

export interface DeviceStateStore {
	version: typeof DEVICE_STORE_VERSION;
	deviceId: string;
	/** Increments on every write to this file. */
	storeRevision: number;
	notes: Record<string, NoteStateEntry>;
	/** Friendly label of this device (e.g. "phone"), so peers can name it in confirmations. */
	deviceName?: string;
	/** noteHash -> highest force-push stamp this device has received/processed. Lets the pusher
	 *  confirm a force actually landed on each peer (not just that the file was written). */
	acks?: Record<string, number>;
	/** noteHash -> number of times THIS device marked the note "revised". This is a G-Counter CRDT:
	 *  the user-facing total for a note is the SUM of this count across every device's store, so
	 *  marking from any device just adds up — no conflicts, no lost increments. */
	revisions?: Record<string, number>;
	/** This device's recently-opened notes, newest-first, capped at RECENTS_LIMIT. Merged with every
	 *  other device's list to produce one unified "recent reading" stack you can jump back into. */
	recents?: RecentVisit[];
}

export function createEmptyDeviceStore(deviceId: string): DeviceStateStore {
	return {
		version: DEVICE_STORE_VERSION,
		deviceId,
		storeRevision: 0,
		notes: {},
	};
}

export function getDeviceStorePath(stateDir: string, deviceId: string): string {
	return `${stateDir}/${deviceId}.json`;
}

export function isSyncConflictFileName(fileName: string): boolean {
	return /\.sync-conflict-/i.test(fileName);
}

export function parseLegacyPerNoteFile(
	fileName: string
): { noteHash: string; deviceId: string | null } | null {
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/i, '');
	if (!base) return null;
	const dash = base.lastIndexOf('-');
	if (dash > 0) {
		return { noteHash: base.slice(0, dash), deviceId: base.slice(dash + 1) };
	}
	return { noteHash: base, deviceId: null };
}

export function parseDeviceStoreJson(raw: string): DeviceStateStore | null {
	try {
		const parsed = JSON.parse(raw) as Partial<DeviceStateStore>;
		if (parsed.version !== DEVICE_STORE_VERSION || !parsed.deviceId) return null;
		return {
			version: DEVICE_STORE_VERSION,
			deviceId: parsed.deviceId,
			storeRevision: parsed.storeRevision ?? 0,
			notes: parsed.notes ?? {},
			deviceName: parsed.deviceName,
			acks: parsed.acks ?? {},
			revisions: parsed.revisions ?? {},
			recents: Array.isArray(parsed.recents) ? parsed.recents : [],
		};
	} catch {
		return null;
	}
}

export function parseLegacyNoteJson(raw: string): EphemeralState | null {
	try {
		const parsed = JSON.parse(raw) as EphemeralState;
		return isValidState(parsed) ? parsed : null;
	} catch {
		return null;
	}
}

/** Merge two device stores for the same deviceId (conflict copies). Revision wins per note. */
export function mergeDeviceStores(a: DeviceStateStore, b: DeviceStateStore): DeviceStateStore {
	if (a.deviceId !== b.deviceId) {
		throw new Error(`Cannot merge stores for different devices: ${a.deviceId} vs ${b.deviceId}`);
	}
	const out: DeviceStateStore = {
		version: DEVICE_STORE_VERSION,
		deviceId: a.deviceId,
		storeRevision: Math.max(a.storeRevision ?? 0, b.storeRevision ?? 0),
		notes: { ...a.notes },
		// Revise-counter is monotonic per device, so the higher value is always the fresher one
		// (conflict copies of the SAME device's file just lost a couple of recent increments).
		revisions: mergeRevisionCounts(a.revisions, b.revisions),
		// One device, two conflict copies → keep each note's most recent open.
		recents: mergeRecentLists([a.recents, b.recents], RECENTS_LIMIT),
	};
	if (a.acks || b.acks) {
		out.acks = { ...(a.acks ?? {}) };
		for (const [hash, stamp] of Object.entries(b.acks ?? {})) {
			out.acks[hash] = Math.max(out.acks[hash] ?? 0, stamp);
		}
	}

	for (const [hash, entry] of Object.entries(b.notes)) {
		const existing = out.notes[hash];
		if (!existing || !isValidState(existing)) {
			out.notes[hash] = entry;
			continue;
		}
		if (!isValidState(entry)) continue;
		const aRev = existing.revision ?? 0;
		const bRev = entry.revision ?? 0;
		if (bRev > aRev) {
			out.notes[hash] = entry;
		} else if (bRev === aRev && (entry.lastModified ?? 0) > (existing.lastModified ?? 0)) {
			out.notes[hash] = entry;
		}
	}
	return out;
}

function mergeRevisionCounts(
	a: Record<string, number> | undefined,
	b: Record<string, number> | undefined
): Record<string, number> {
	const out: Record<string, number> = { ...(a ?? {}) };
	for (const [hash, count] of Object.entries(b ?? {})) {
		out[hash] = Math.max(out[hash] ?? 0, count);
	}
	return out;
}

/** Combine several recents lists into one newest-first, path-deduped stack (max ts per path), capped. */
function mergeRecentLists(lists: Array<RecentVisit[] | undefined>, limit: number): RecentVisit[] {
	const byPath = new Map<string, RecentVisit>();
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

/** Add `delta` to THIS device's revise-count for a note (floored at 0). Bumps storeRevision so peers notice. */
export function incrementOwnRevision(
	store: DeviceStateStore,
	notePath: string,
	delta = 1
): DeviceStateStore {
	const hash = getFileHash(notePath);
	const current = store.revisions?.[hash] ?? 0;
	const next = Math.max(0, current + delta);
	return {
		...store,
		storeRevision: (store.storeRevision ?? 0) + 1,
		revisions: { ...(store.revisions ?? {}), [hash]: next },
	};
}

/** Times THIS device alone has marked a note revised. */
export function getOwnRevisionCount(store: DeviceStateStore, notePath: string): number {
	return store.revisions?.[getFileHash(notePath)] ?? 0;
}

/** User-facing total: revise-counts for a note summed across every device's store. */
export function getTotalRevisionCount(stores: DeviceStateStore[], notePath: string): number {
	const hash = getFileHash(notePath);
	let total = 0;
	for (const store of stores) {
		total += store.revisions?.[hash] ?? 0;
	}
	return total;
}

/** Record that THIS device just opened a note: move it to the front of the recents stack, capped. */
export function recordRecentVisit(
	store: DeviceStateStore,
	notePath: string,
	ts: number,
	limit = RECENTS_LIMIT
): DeviceStateStore {
	const hash = getFileHash(notePath);
	const rest = (store.recents ?? []).filter((r) => r.path !== notePath);
	const recents = [{ path: notePath, hash, ts }, ...rest].slice(0, limit);
	return {
		...store,
		storeRevision: (store.storeRevision ?? 0) + 1,
		recents,
	};
}

/** The unified recent-reading stack across all devices: newest-first, one row per note. */
export function mergeRecentVisits(stores: DeviceStateStore[], limit = RECENTS_LIMIT): RecentVisit[] {
	return mergeRecentLists(stores.map((s) => s.recents), limit);
}

export function upsertNoteInStore(
	store: DeviceStateStore,
	notePath: string,
	state: EphemeralState
): DeviceStateStore {
	const hash = getFileHash(notePath);
	const nextRevision = (store.storeRevision ?? 0) + 1;
	const entry: NoteStateEntry = {
		...state,
		filePath: notePath,
		lastModified: state.lastModified ?? Date.now(),
		revision: nextRevision,
	};
	return {
		...store,
		storeRevision: nextRevision,
		notes: {
			...store.notes,
			[hash]: entry,
		},
	};
}

/** Highest force-push stamp this store has acknowledged for a note (0 = none). */
export function getForceAck(store: DeviceStateStore, noteHash: string): number {
	return store.acks?.[noteHash] ?? 0;
}

/** Record that this device has received a force-push for a note. Returns the same store object
 *  unchanged if the stamp was already acknowledged (so it never triggers a pointless re-write). */
export function recordForceAck(
	store: DeviceStateStore,
	noteHash: string,
	forcedAt: number
): DeviceStateStore {
	if (forcedAt <= getForceAck(store, noteHash)) return store;
	return {
		...store,
		storeRevision: (store.storeRevision ?? 0) + 1,
		acks: { ...(store.acks ?? {}), [noteHash]: forcedAt },
	};
}

export function noteEntryToTagged(
	entry: NoteStateEntry,
	sourceDeviceId: string
): TaggedNoteState {
	return {
		...entry,
		sourceDeviceId,
		revision: entry.revision,
	};
}

export function collectTaggedStatesForNote(
	stores: DeviceStateStore[],
	notePath: string
): TaggedNoteState[] {
	const hash = getFileHash(notePath);
	const tagged: TaggedNoteState[] = [];
	for (const store of stores) {
		const entry = store.notes[hash];
		if (entry && isValidState(entry)) {
			tagged.push(noteEntryToTagged(entry, store.deviceId));
		}
	}
	return tagged;
}

export interface ConflictReapResult {
	merged: number;
	deleted: number;
	errors: string[];
}

export interface StateFileAdapter {
	listFiles(stateDir: string): Promise<string[]>;
	exists(path: string): Promise<boolean>;
	read(path: string): Promise<string>;
	write(path: string, content: string): Promise<void>;
	remove(path: string): Promise<void>;
}

/**
 * Scan states/ for *.sync-conflict-* files, merge into canonical store by revision / lastModified, delete copies.
 */
export async function reapStateConflicts(
	stateDir: string,
	adapter: StateFileAdapter
): Promise<ConflictReapResult> {
	const result: ConflictReapResult = { merged: 0, deleted: 0, errors: [] };
	const files = await adapter.listFiles(stateDir);
	const conflicts = files.filter((f) => isSyncConflictFileName(f.split('/').pop() ?? f));
	if (conflicts.length === 0) return result;

	const byCanonical = new Map<string, string[]>();
	for (const path of conflicts) {
		const fileName = path.split('/').pop() ?? path;
		const canonicalName = normalizeStateFileBaseName(fileName);
		const list = byCanonical.get(canonicalName) ?? [];
		list.push(path);
		byCanonical.set(canonicalName, list);
	}

	for (const [canonicalName, conflictPaths] of byCanonical) {
		const canonicalPath = `${stateDir}/${canonicalName}`;
		try {
			let mergedStore: DeviceStateStore | null = null;
			let mergedLegacy: EphemeralState | null = null;
			const isStore = isDeviceStoreFileName(canonicalName);

			if (await adapter.exists(canonicalPath)) {
				const raw = await adapter.read(canonicalPath);
				if (isStore) {
					mergedStore = parseDeviceStoreJson(raw);
				} else {
					mergedLegacy = parseLegacyNoteJson(raw);
				}
			}

			for (const conflictPath of conflictPaths) {
				const raw = await adapter.read(conflictPath);
				if (isStore) {
					const conflictStore = parseDeviceStoreJson(raw);
					if (!conflictStore) continue;
					mergedStore = mergedStore
						? mergeDeviceStores(mergedStore, conflictStore)
						: conflictStore;
				} else {
					const conflictState = parseLegacyNoteJson(raw);
					if (!conflictState) continue;
					if (!mergedLegacy) {
						mergedLegacy = conflictState;
					} else {
						const pick = mergeStatesFromAll([mergedLegacy, conflictState]);
						if (pick) mergedLegacy = pick;
					}
				}
			}

			if (isStore && mergedStore) {
				await adapter.write(canonicalPath, JSON.stringify(mergedStore));
				result.merged++;
			} else if (!isStore && mergedLegacy) {
				await adapter.write(canonicalPath, JSON.stringify(mergedLegacy));
				result.merged++;
			}

			for (const conflictPath of conflictPaths) {
				await adapter.remove(conflictPath);
				result.deleted++;
			}
		} catch (e) {
			result.errors.push(
				`${canonicalName}: ${e instanceof Error ? e.message : String(e)}`
			);
		}
	}

	return result;
}

export interface MigrationResult {
	storesWritten: number;
	legacyRemoved: number;
	notesMigrated: number;
}

/** Import legacy per-note JSON files into v2 device stores, then remove legacy files. */
export async function migrateLegacyFilesToDeviceStores(
	stateDir: string,
	ownDeviceId: string,
	adapter: StateFileAdapter
): Promise<MigrationResult> {
	const result: MigrationResult = { storesWritten: 0, legacyRemoved: 0, notesMigrated: 0 };
	const files = await adapter.listFiles(stateDir);
	const stores = new Map<string, DeviceStateStore>();

	const ensureStore = (deviceId: string): DeviceStateStore => {
		let s = stores.get(deviceId);
		if (!s) {
			s = createEmptyDeviceStore(deviceId);
			stores.set(deviceId, s);
		}
		return s;
	};

	// Load existing v2 stores first
	for (const path of files) {
		const name = path.split('/').pop() ?? path;
		if (!isDeviceStoreFileName(name) || isSyncConflictFileName(name)) continue;
		const raw = await adapter.read(path);
		const store = parseDeviceStoreJson(raw);
		if (store) stores.set(store.deviceId, store);
	}

	for (const path of files) {
		const name = path.split('/').pop() ?? path;
		if (isSyncConflictFileName(name)) continue;
		if (isDeviceStoreFileName(name)) continue;

		if (!isLegacyPerNoteStateFileName(name)) continue;

		const parsed = parseLegacyPerNoteFile(name);
		if (!parsed) continue;

		const raw = await adapter.read(path);
		const state = parseLegacyNoteJson(raw);
		if (!state || !state.filePath) continue;

		const targetDeviceId = parsed.deviceId ?? ownDeviceId;
		const store = ensureStore(targetDeviceId);
		const updated = upsertNoteInStore(store, state.filePath, state);
		stores.set(targetDeviceId, updated);
		result.notesMigrated++;
		result.legacyRemoved++;
		await adapter.remove(path);
	}

	for (const [deviceId, store] of stores) {
		const outPath = getDeviceStorePath(stateDir, deviceId);
		await adapter.write(outPath, JSON.stringify(store));
		result.storesWritten++;
	}

	return result;
}

export interface StateDirMigrationResult {
	filesCopied: number;
	filesMerged: number;
	filesRemoved: number;
	errors: string[];
}

/** Move device store files from an old folder (e.g. plugin/states) into the new LiveSync-friendly dir. */
export async function migrateStateDirBetween(
	fromDir: string,
	toDir: string,
	adapter: StateFileAdapter
): Promise<StateDirMigrationResult> {
	const result: StateDirMigrationResult = {
		filesCopied: 0,
		filesMerged: 0,
		filesRemoved: 0,
		errors: [],
	};

	if (fromDir === toDir) return result;
	if (!(await adapter.exists(fromDir))) return result;

	if (!(await adapter.exists(toDir))) {
		// mkdir is handled by plugin ensureStateDir; list may still work on empty parent
	}

	const fromFiles = await adapter.listFiles(fromDir);
	for (const fromPath of fromFiles) {
		const name = fromPath.split('/').pop() ?? fromPath;
		if (!isDeviceStoreFileName(name) || isSyncConflictFileName(name)) continue;

		const toPath = `${toDir}/${name}`;
		try {
			const fromRaw = await adapter.read(fromPath);
			const fromStore = parseDeviceStoreJson(fromRaw);
			if (!fromStore) continue;

			if (await adapter.exists(toPath)) {
				const toRaw = await adapter.read(toPath);
				const toStore = parseDeviceStoreJson(toRaw);
				if (toStore && toStore.deviceId === fromStore.deviceId) {
					const merged = mergeDeviceStores(toStore, fromStore);
					await adapter.write(toPath, JSON.stringify(merged));
					result.filesMerged++;
				} else {
					await adapter.write(toPath, fromRaw);
					result.filesCopied++;
				}
			} else {
				await adapter.write(toPath, fromRaw);
				result.filesCopied++;
			}

			await adapter.remove(fromPath);
			result.filesRemoved++;
		} catch (e) {
			result.errors.push(
				`${name}: ${e instanceof Error ? e.message : String(e)}`
			);
		}
	}

	return result;
}

export function pruneDeviceStore(
	store: DeviceStateStore,
	options: {
		maxAgeDays: number;
		maxCount: number;
		noteExists: (filePath: string) => boolean;
	}
): { store: DeviceStateStore; removed: number } {
	const { maxAgeDays, maxCount, noteExists } = options;
	let notes = { ...store.notes };
	let removed = 0;

	for (const [hash, entry] of Object.entries(notes)) {
		if (!entry.filePath || !noteExists(entry.filePath)) {
			delete notes[hash];
			removed++;
		}
	}

	if (maxAgeDays > 0) {
		const cutoff = Date.now() - maxAgeDays * 86400000;
		for (const [hash, entry] of Object.entries(notes)) {
			if ((entry.lastModified ?? 0) < cutoff) {
				delete notes[hash];
				removed++;
			}
		}
	}

	if (maxCount > 0) {
		const entries = Object.entries(notes).sort(
			(a, b) => (b[1].lastModified ?? 0) - (a[1].lastModified ?? 0)
		);
		if (entries.length > maxCount) {
			for (const [hash] of entries.slice(maxCount)) {
				delete notes[hash];
				removed++;
			}
		}
	}

	return { store: { ...store, notes }, removed };
}
