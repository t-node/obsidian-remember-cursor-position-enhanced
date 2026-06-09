#!/usr/bin/env node
/**
 * Safe Syncthing / Obsidian vault cleanup.
 *
 * Removes ONLY junk — never deletes real notes, workspace.json, or device state stores.
 *
 * Usage:
 *   node scripts/vault-cleanup.mjs
 *   node scripts/vault-cleanup.mjs "C:\path\to\vault"
 *   set OBSIDIAN_VAULT=C:\notes1 && npm run vault-cleanup
 *
 * Close Obsidian on all devices before running.
 * After cleanup: Syncthing → Rescan on each device.
 */

import {
	existsSync,
	readdirSync,
	rmSync,
	statSync,
	unlinkSync,
} from 'node:fs';
import { join, resolve } from 'node:path';

const vault = resolve(process.argv[2] ?? process.env.OBSIDIAN_VAULT ?? 'C:\\notes1');

const SYNC_CONFLICT_RE = /\.sync-conflict-/i;
const SYNCTHING_TMP_RE = /^~syncthing~/i;
const STFOLDER_REMOVED_RE = /^\.stfolder\.removed-/i;

const stats = {
	filesRemoved: 0,
	dirsRemoved: 0,
	bytesFreed: 0,
	errors: [],
};

function isSyncJunk(fileName) {
	return SYNC_CONFLICT_RE.test(fileName) || SYNCTHING_TMP_RE.test(fileName);
}

function removeFile(filePath) {
	try {
		const size = statSync(filePath).size;
		unlinkSync(filePath);
		stats.filesRemoved++;
		stats.bytesFreed += size;
		console.log(`  - file  ${filePath}`);
	} catch (e) {
		stats.errors.push(`${filePath}: ${e.message}`);
	}
}

function removeDir(dirPath) {
	try {
		rmSync(dirPath, { recursive: true, force: true });
		stats.dirsRemoved++;
		console.log(`  - dir   ${dirPath}`);
	} catch (e) {
		stats.errors.push(`${dirPath}: ${e.message}`);
	}
}

function walk(dir) {
	let entries;
	try {
		entries = readdirSync(dir, { withFileTypes: true });
	} catch (e) {
		stats.errors.push(`${dir}: ${e.message}`);
		return;
	}

	for (const entry of entries) {
		const full = join(dir, entry.name);

		if (entry.isDirectory()) {
			if (STFOLDER_REMOVED_RE.test(entry.name)) {
				removeDir(full);
				continue;
			}
			// Don't recurse into .git if present
			if (entry.name === '.git') continue;
			walk(full);
			continue;
		}

		if (entry.isFile() && isSyncJunk(entry.name)) {
			removeFile(full);
		}
	}
}

function emptyLogDir(logDir) {
	if (!existsSync(logDir)) return;
	for (const name of readdirSync(logDir)) {
		const full = join(logDir, name);
		try {
			if (statSync(full).isFile()) {
				removeFile(full);
			}
		} catch (e) {
			stats.errors.push(`${full}: ${e.message}`);
		}
	}
}

function formatBytes(n) {
	if (n < 1024) return `${n} B`;
	if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
	return `${(n / (1024 * 1024)).toFixed(2)} MB`;
}

console.log(`\nRCP-E vault cleanup`);
console.log(`Vault: ${vault}\n`);

if (!existsSync(vault)) {
	console.error(`Vault not found: ${vault}`);
	process.exit(1);
}

console.log('Scanning for *.sync-conflict-* and ~syncthing~* files...');
walk(vault);

const logDir = join(vault, 'rcp-enhanced-logs');
console.log(`\nClearing ${logDir}...`);
emptyLogDir(logDir);

console.log('\n--- Summary ---');
console.log(`Files removed: ${stats.filesRemoved}`);
console.log(`Folders removed: ${stats.dirsRemoved}`);
console.log(`Space freed:   ${formatBytes(stats.bytesFreed)}`);
if (stats.errors.length > 0) {
	console.log(`Errors:        ${stats.errors.length}`);
	for (const err of stats.errors) console.log(`  ! ${err}`);
}

console.log(`
Next steps:
  1. Syncthing → Rescan on EVERY device
  2. Repeat this script on phone/PC if conflicts reappear from stale peers
  3. Keep .stignore rules so new conflicts are not synced
`);

process.exit(stats.errors.length > 0 ? 1 : 0);
