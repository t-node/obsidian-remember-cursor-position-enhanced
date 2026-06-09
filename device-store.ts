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

export interface NoteStateEntry extends EphemeralState {
	/** Monotonic save counter on this device (hybrid clock). */
	revision?: number;
}

export interface DeviceStateStore {
	version: typeof DEVICE_STORE_VERSION;
	deviceId: string;
	/** Increments on every write to this file. */
	storeRevision: number;
	notes: Record<string, NoteStateEntry>;
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
	};

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
