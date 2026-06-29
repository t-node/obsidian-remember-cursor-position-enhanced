export interface EphemeralState {
	filePath?: string;
	cursor?: {
		from: { ch: number; line: number };
		to: { ch: number; line: number };
	};
	scroll?: number;
	lastModified?: number;
	/** Monotonic revision on the source device (hybrid clock). */
	revision?: number;
	/** Skew-proof cross-device priority TIER (default 0). Compared BEFORE `lastModified`, so a higher
	 *  tier always wins regardless of any device's wall-clock. A force-push bumps the tier above every
	 *  state it can see; every later save inherits the current tier. This is what makes a force STICK:
	 *  a stale / clock-skewed / orphaned state sitting at a lower tier can never revert it, while normal
	 *  forward reading (same tier, newer `lastModified`) still wins exactly as before. Tier 0 everywhere
	 *  == legacy behavior, so notes you never force behave identically to today. */
	authority?: number;
	/** Nearest heading line above cursor (cross-device anchor). */
	anchorLine?: number;
	/** Set ONLY by a deliberate force-push. Tells receivers to apply this state immediately,
	 *  overriding the active-reading and weak-scroll guards. Value is the push timestamp, used
	 *  by receivers to dedupe (honor each force exactly once). */
	forcedAt?: number;
	/** Set when the force-push should also OPEN this note on the other devices ("follow me"), not just
	 *  sync the position once they're already on it. Receivers open the note on the newest such push. */
	forcedOpen?: boolean;
}

export interface TaggedNoteState extends EphemeralState {
	sourceDeviceId?: string;
}

/** Wall-clock skew threshold (ms) before logging a suspected fast/slow device clock. Lowered to 5s
 *  because a force-push only beats the visible state by +2s — any device whose clock is more than a
 *  few seconds ahead can outrank a force, which is exactly the "it reverted to an old state" symptom.
 *  We want that skew surfaced in the logs, not hidden under a 2-minute threshold. */
export const CLOCK_SKEW_LOG_THRESHOLD_MS = 5_000;

/**
 * Scroll values within this many units are treated as the SAME position. Cross-device
 * restores land a fraction of a line off (e.g. 211.39 vs 210.96); without this tolerance the
 * tiny difference reads as a "new scroll", gets re-saved with a fresh timestamp, and bounces
 * between devices forever — the note appears stuck at one position ("always Q11"). Sub-line, so
 * imperceptible to the reader.
 */
export const SCROLL_EQ_EPSILON = 2;

export function getFileHash(filePath: string): string {
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

/** Legacy shared path — read-only after v2 migration. */
export function getStateFilePath(stateDir: string, notePath: string): string {
	return `${stateDir}/${getFileHash(notePath)}.json`;
}

/** Legacy per-(note×device) path — read-only after v2 migration. */
export function getPerDeviceStateFilePath(
	stateDir: string,
	notePath: string,
	deviceId: string
): string {
	return `${stateDir}/${getFileHash(notePath)}-${deviceId}.json`;
}

export function normalizeStateFileBaseName(fileName: string): string {
	return fileName.replace(/\.sync-conflict-[^/\\]+(?=\.json$)/i, '');
}

/** v2 consolidated store: states/{deviceId}.json (no hyphen in basename). */
export function isDeviceStoreFileName(fileName: string): boolean {
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/i, '');
	if (!base || base.includes('-')) return false;
	// Device IDs are always 8 chars (Math.random().toString(36).slice(2, 10)).
	return /^[a-z0-9]{8}$/i.test(base);
}

export function isLegacyPerNoteStateFileName(fileName: string): boolean {
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/i, '');
	if (!base) return false;
	if (base.includes('-')) return true;
	return base.length > 16;
}

export function stateFileBelongsToNote(stateDir: string, notePath: string, filePath: string): boolean {
	if (!filePath.startsWith(stateDir + '/') || !filePath.endsWith('.json')) {
		return false;
	}
	const hash = getFileHash(notePath);
	const base = normalizeStateFileBaseName(filePath.split('/').pop() ?? '').replace(/\.json$/, '');
	return base === hash || base.startsWith(hash + '-');
}

export function isStateFilePath(stateDir: string, path: string): boolean {
	if (!path.startsWith(stateDir + '/') || !path.endsWith('.json')) {
		return false;
	}
	const fileName = path.split('/').pop() ?? '';
	if (fileName.startsWith('~syncthing~') || fileName.includes('.tmp')) {
		return false;
	}
	if (isSyncConflictStatePath(fileName)) return true;
	if (isDeviceStoreFileName(fileName)) return true;
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/, '');
	return /^[a-z0-9]+(-[a-z0-9]+)?$/i.test(base);
}

export function isSyncConflictStatePath(fileName: string): boolean {
	return /\.sync-conflict-/i.test(fileName);
}

export function isIgnorableStateListEntry(filePath: string): boolean {
	const fileName = filePath.split('/').pop() ?? filePath;
	return fileName.startsWith('~syncthing~') || fileName.includes('.tmp');
}

export function isValidState(st: EphemeralState): boolean {
	return !!(st.cursor || (st.scroll != null && !isNaN(st.scroll)));
}

export function isEphemeralStatesEquals(state1: EphemeralState, state2: EphemeralState): boolean {
	if (state1.cursor && !state2.cursor) return false;
	if (!state1.cursor && state2.cursor) return false;

	if (state1.cursor) {
		if (state1.cursor.from.ch !== state2.cursor!.from.ch) return false;
		if (state1.cursor.from.line !== state2.cursor!.from.line) return false;
		if (state1.cursor.to.ch !== state2.cursor!.to.ch) return false;
		if (state1.cursor.to.line !== state2.cursor!.to.line) return false;
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

export function mergeStatesByTimestamp(
	incoming: EphemeralState,
	local: EphemeralState | null | undefined
): EphemeralState {
	const incomingTime = incoming.lastModified ?? 0;
	const localTime = local?.lastModified ?? 0;
	return incomingTime >= localTime ? incoming : (local as EphemeralState);
}

/**
 * Compare two states from the same device: higher revision wins (immune to clock skew).
 * Returns positive if `a` is newer than `b`.
 */
export function compareSameDeviceRevision(a: EphemeralState, b: EphemeralState): number {
	const revA = a.revision ?? 0;
	const revB = b.revision ?? 0;
	if (revA !== revB) return revA - revB;
	return (a.lastModified ?? 0) - (b.lastModified ?? 0);
}

/**
 * Compare states from different devices. The skew-proof `authority` TIER is decisive; only within the
 * same tier do we fall back to wall-clock `lastModified` (the legacy comparison). Returns positive if
 * `a` ranks newer than `b`. Because every normal state is tier 0, this is identical to the old
 * lastModified comparison for any note that has never been force-pushed.
 */
export function compareAcrossDevices(a: TaggedNoteState, b: TaggedNoteState): number {
	const authDiff = (a.authority ?? 0) - (b.authority ?? 0);
	if (authDiff !== 0) return authDiff;
	return (a.lastModified ?? 0) - (b.lastModified ?? 0);
}

/** Detect likely clock skew when timestamps disagree with revision ordering. */
export function describeClockSkew(
	winner: TaggedNoteState,
	loser: TaggedNoteState
): string | null {
	if (!winner.sourceDeviceId || !loser.sourceDeviceId) return null;
	if (winner.sourceDeviceId === loser.sourceDeviceId) return null;

	const timeDiff = (winner.lastModified ?? 0) - (loser.lastModified ?? 0);
	const revDiff = (winner.revision ?? 0) - (loser.revision ?? 0);

	if (timeDiff > 0 && revDiff < 0 && Math.abs(timeDiff) > CLOCK_SKEW_LOG_THRESHOLD_MS) {
		return (
			`Possible clock skew: ${winner.sourceDeviceId} won on timestamp (+${timeDiff}ms) ` +
			`but ${loser.sourceDeviceId} has higher revision (${loser.revision} vs ${winner.revision})`
		);
	}
	if (timeDiff < 0 && revDiff > 0 && Math.abs(timeDiff) > CLOCK_SKEW_LOG_THRESHOLD_MS) {
		return (
			`Possible clock skew: ${loser.sourceDeviceId} has newer timestamp but lost to ` +
			`${winner.sourceDeviceId} revision (${winner.revision} vs ${loser.revision})`
		);
	}
	return null;
}

function pickNewerTagged(a: TaggedNoteState, b: TaggedNoteState): TaggedNoteState {
	if (a.sourceDeviceId && b.sourceDeviceId && a.sourceDeviceId === b.sourceDeviceId) {
		return compareSameDeviceRevision(a, b) >= 0 ? a : b;
	}
	return compareAcrossDevices(a, b) >= 0 ? a : b;
}

/** True when a save would move scroll back toward the top while disk already has a deeper position. */
export function isRegressiveScrollSave(proposed: EphemeralState, existing: EphemeralState): boolean {
	if (proposed.scroll == null || existing.scroll == null) return false;
	// A higher-tier (e.g. force-bumped) position is a deliberate authority change, never "regressive".
	if ((proposed.authority ?? 0) > (existing.authority ?? 0)) return false;
	if ((proposed.lastModified ?? 0) > (existing.lastModified ?? 0)) return false;
	if (
		proposed.revision != null &&
		existing.revision != null &&
		proposed.revision > existing.revision
	) {
		return false;
	}
	return proposed.scroll < existing.scroll - 5 && existing.scroll > 20;
}

/** Pick the newest valid state across devices (hybrid clock) with weak-scroll-0 guard. */
export function mergeStatesFromAll(sources: EphemeralState[]): EphemeralState | null;
export function mergeStatesFromAll(
	sources: TaggedNoteState[],
	options?: { onSkewDetected?: (message: string) => void }
): EphemeralState | null;
export function mergeStatesFromAll(
	sources: (EphemeralState | TaggedNoteState)[],
	options?: { onSkewDetected?: (message: string) => void }
): EphemeralState | null {
	const valid = sources.filter((st) => isValidState(st));
	if (valid.length === 0) return null;

	const tagged = valid as TaggedNoteState[];
	let newest = tagged[0];
	for (const candidate of tagged.slice(1)) {
		const picked = pickNewerTagged(newest, candidate);
		if (picked !== newest) {
			const skew = describeClockSkew(picked, newest);
			if (skew) options?.onSkewDetected?.(skew);
		}
		newest = picked;
	}

	for (const candidate of tagged) {
		if (candidate === newest) continue;
		if (
			(candidate.scroll ?? 0) > 20 &&
			isWeakDefaultScrollSave(newest, candidate)
		) {
			return candidate;
		}
	}

	const { sourceDeviceId: _s, ...rest } = newest;
	return rest;
}

export function isWeakTopOfNoteState(state: EphemeralState): boolean {
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

/** Caret at document origin (line 0) regardless of scroll — scroll-only reading on mobile. */
export function isCaretAtOrigin(state: EphemeralState): boolean {
	if (!state.cursor) return true;
	return (
		state.cursor.from.line === 0 &&
		state.cursor.from.ch === 0 &&
		state.cursor.to.line === 0 &&
		state.cursor.to.ch === 0
	);
}

export function isWeakDefaultScrollSave(
	proposed: EphemeralState,
	existing: EphemeralState
): boolean {
	if (existing.scroll == null || existing.scroll <= 20) return false;
	return isWeakTopOfNoteState(proposed);
}

/** v2: states/{deviceId}.json — legacy: *-{deviceId}.json */
export function isOwnDeviceStateFile(stateFilePath: string, deviceId: string): boolean {
	const fileName = stateFilePath.split('/').pop() ?? stateFilePath;
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/i, '');
	return base === deviceId || base.endsWith(`-${deviceId}`);
}

export function getDeviceIdFromStorePath(stateFilePath: string): string | null {
	const fileName = stateFilePath.split('/').pop() ?? '';
	const base = normalizeStateFileBaseName(fileName).replace(/\.json$/i, '');
	if (isDeviceStoreFileName(fileName)) return base;
	const dash = base.lastIndexOf('-');
	if (dash > 0) return base.slice(dash + 1);
	return null;
}

export function shouldWatchForRemoteState(
	stateFiles: string[],
	deviceId: string,
	merged: EphemeralState | null
): boolean {
	if (stateFiles.length === 0) return true;
	const hasRemote = stateFiles.some((f) => {
		const id = getDeviceIdFromStorePath(f);
		return id != null && id !== deviceId;
	});
	if (hasRemote) return false;
	return !merged || isWeakTopOfNoteState(merged);
}

/**
 * True when a save reflects the user's CURRENT, deliberate editor position — and so must win over
 * the load-time scroll-0 guard and the cross-device staleness guard. Deliberate = not loading /
 * reloading, past the restore-grace window, and the user interacted within `windowMs`. During load
 * or restore (none of those true) the guards still apply, preserving the original protection
 * against clobbering a real saved position with a bogus scroll-0 reported before the editor is ready.
 */
export function isDeliberateUserSave(p: {
	now: number;
	lastInteractionAt: number;
	restoreGraceUntil: number;
	loadingFile: boolean;
	reloadingState: boolean;
	windowMs: number;
}): boolean {
	if (p.loadingFile || p.reloadingState) return false;
	if (p.now < p.restoreGraceUntil) return false;
	return p.now - p.lastInteractionAt < p.windowMs;
}

/** A force-push carries a `forcedAt` stamp. The receiver honors it exactly once — deduped by the
 *  stamp value (skew-proof: it's an identity check, not a clock comparison) — and when honored it
 *  overrides the active-reading and weak-scroll guards. This is what makes "force" mean force:
 *  pressing the button updates every open screen in real time, even one mid-scroll. */
export function isForceOverride(
	merged: EphemeralState | null | undefined,
	lastAppliedForcedAt: number
): boolean {
	if (!merged || typeof merged.forcedAt !== 'number') return false;
	return merged.forcedAt !== lastAppliedForcedAt;
}

export function shouldApplyMergedState(
	disk: EphemeralState,
	applied: EphemeralState | null | undefined
): boolean {
	if (!isValidState(disk)) return false;
	if (!applied || !isValidState(applied)) return true;
	if (isEphemeralStatesEquals(disk, applied)) return false;

	const diskScroll = disk.scroll ?? 0;
	const appliedScroll = applied.scroll ?? 0;

	// Clock-skew-proof guard: a weak top-of-note / "default" incoming state must NEVER
	// override a substantial existing reading position, even if its wall-clock looks newer.
	// This is the root of the "I scroll down, it snaps back to the top" symptom.
	if (appliedScroll > 20 && isWeakTopOfNoteState(disk) && !isWeakTopOfNoteState(applied)) {
		return false;
	}

	if (diskScroll > 20 && isWeakDefaultScrollSave(applied, disk)) {
		return true;
	}

	// Skew-proof tier first: a higher-authority merged state (e.g. a force-push, or a position saved
	// in the forced tier) applies even if its wall-clock looks older — that's the whole point of the
	// tier. The weak-top guard above still runs FIRST, so a weak/top-of-note state never clobbers real
	// reading even at a higher tier. Within the same tier we keep the exact legacy lastModified rule.
	const diskAuth = disk.authority ?? 0;
	const appliedAuth = applied.authority ?? 0;
	if (diskAuth > appliedAuth) return true;
	if (appliedAuth > diskAuth) return false;

	// Recency is decided by wall-clock (lastModified) only, matching the cross-device merge
	// comparator (compareAcrossDevices). `revision` is a PER-DEVICE counter and must NOT gate
	// applies: comparing it across devices let whichever device had the higher counter win
	// forever and reject every other device's genuinely newer position (the "my scroll position
	// never syncs to other devices" bug). Same-device revision ordering is already resolved by
	// the merge (compareSameDeviceRevision) before this function is reached.
	const diskTime = disk.lastModified ?? 0;
	const appliedTime = applied.lastModified ?? 0;
	if (appliedTime > diskTime) return false;
	if (diskTime > appliedTime) return true;
	return false;
}

export interface MergeCandidateSummary {
	deviceId: string;
	scroll?: number;
	cursorLine?: number;
	anchorLine?: number;
	lastModified?: number;
	revision?: number;
	/** Skew-proof priority tier (see EphemeralState.authority). Shown so the diag makes clear WHY a
	 *  candidate won — a higher tier beats wall-clock. */
	authority?: number;
	/** Set when this candidate carries a force-push stamp — lets the diag show whether the winner
	 *  was a deliberate force or whether a force LOST to a higher (possibly skewed) wall-clock. */
	forcedAt?: number;
}

export interface MergeAnalysis {
	merged: EphemeralState | null;
	winnerDeviceId: string | null;
	candidates: MergeCandidateSummary[];
	weakScrollOverride?: string;
}

function summarizeCandidate(st: TaggedNoteState): MergeCandidateSummary {
	return {
		deviceId: st.sourceDeviceId ?? '?',
		scroll: st.scroll,
		cursorLine: st.cursor?.from.line,
		anchorLine: st.anchorLine,
		lastModified: st.lastModified,
		revision: st.revision,
		authority: st.authority,
		forcedAt: st.forcedAt,
	};
}

/**
 * Spot the "my force-push got reverted to an old state" case directly in the merge result: a candidate
 * carried a force-push stamp but did NOT win, because another device's plain (un-forced) state had a
 * higher wall-clock `lastModified`. That higher timestamp is almost always clock skew on the winning
 * device (often an orphaned/stale store), and it's the precise event we want flagged in the logs.
 */
export function detectForceOutranked(
	sources: TaggedNoteState[],
	winnerDeviceId: string | null
): { forcedDeviceId: string; winnerDeviceId: string | null; skewMs: number; forcedAt: number } | null {
	const forced = sources.filter((s) => typeof s.forcedAt === 'number');
	if (forced.length === 0) return null;
	const winner = sources.find((s) => s.sourceDeviceId === winnerDeviceId) ?? null;
	const winnerAuth = winner?.authority ?? 0;
	for (const f of forced) {
		if (f.sourceDeviceId === winnerDeviceId) continue; // the force won — fine
		// With the authority tier in place, a force should only ever lose to a STRICTLY HIGHER tier
		// (i.e. a newer, legitimate force). If it lost to an equal/lower tier, that's the real bug —
		// wall-clock/skew beat a force despite the tiering — and exactly what we want flagged.
		if (winnerAuth > (f.authority ?? 0)) continue;
		const skewMs = (winner?.lastModified ?? 0) - (f.lastModified ?? 0);
		return {
			forcedDeviceId: f.sourceDeviceId ?? '?',
			winnerDeviceId,
			skewMs,
			forcedAt: f.forcedAt as number,
		};
	}
	return null;
}

/** Merge with full audit trail for debug logging. */
export function analyzeMergeForNote(
	sources: TaggedNoteState[],
	options?: { onSkewDetected?: (message: string) => void }
): MergeAnalysis {
	const valid = sources.filter((st) => isValidState(st));
	const candidates = valid.map(summarizeCandidate);
	if (valid.length === 0) {
		return { merged: null, winnerDeviceId: null, candidates };
	}

	let newest = valid[0];
	for (const candidate of valid.slice(1)) {
		const picked = pickNewerTagged(newest, candidate);
		if (picked !== newest) {
			const skew = describeClockSkew(picked, newest);
			if (skew) options?.onSkewDetected?.(skew);
		}
		newest = picked;
	}

	let weakScrollOverride: string | undefined;
	for (const candidate of valid) {
		if (candidate === newest) continue;
		if (
			(candidate.scroll ?? 0) > 20 &&
			isWeakDefaultScrollSave(newest, candidate)
		) {
			newest = candidate;
			weakScrollOverride = `weak-scroll-0 from ${newest.sourceDeviceId} beat timestamp winner`;
			break;
		}
	}

	const { sourceDeviceId, ...rest } = newest;
	return {
		merged: rest,
		winnerDeviceId: sourceDeviceId ?? null,
		candidates,
		weakScrollOverride,
	};
}

/** Human-readable reason when shouldApplyMergedState returns false. */
export function explainApplyRejection(
	disk: EphemeralState,
	applied: EphemeralState | null | undefined
): string {
	if (!isValidState(disk)) return 'merged state invalid';
	if (!applied || !isValidState(applied)) return 'no local state — would apply';
	if (isEphemeralStatesEquals(disk, applied)) return 'already equal to editor state';

	const diskScroll = disk.scroll ?? 0;
	const appliedScroll = applied.scroll ?? 0;
	if (appliedScroll > 20 && isWeakTopOfNoteState(disk) && !isWeakTopOfNoteState(applied)) {
		return 'held — incoming is weak top-of-note over a substantial local position';
	}
	if (diskScroll > 20 && isWeakDefaultScrollSave(applied, disk)) {
		return 'would apply (weak local top-of-note vs remote scroll)';
	}

	const diskAuth = disk.authority ?? 0;
	const appliedAuth = applied.authority ?? 0;
	if (diskAuth > appliedAuth) return `would apply (higher authority tier: ${diskAuth} > ${appliedAuth})`;
	if (appliedAuth > diskAuth) return `held — local is a higher authority tier (${appliedAuth} > ${diskAuth})`;

	const diskTime = disk.lastModified ?? 0;
	const appliedTime = applied.lastModified ?? 0;
	if (appliedTime > diskTime) {
		return `local timestamp newer (${appliedTime} > ${diskTime})`;
	}
	if (diskTime > appliedTime) {
		return `would apply (merged timestamp newer: ${diskTime} > ${appliedTime})`;
	}
	return 'states differ but timestamps tied';
}

/** Find the nearest markdown heading line at or above `line` (for cross-device anchor). */
export function findNearestHeadingLine(lines: string[], line: number): number {
	const clamped = Math.max(0, Math.min(line, lines.length - 1));
	for (let i = clamped; i >= 0; i--) {
		if (/^#{1,6}\s/.test(lines[i])) return i;
	}
	return clamped;
}

export function getAnchorLineFromState(state: EphemeralState): number | undefined {
	if (state.anchorLine != null) return state.anchorLine;
	return state.cursor?.from.line;
}
