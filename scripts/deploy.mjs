/**
 * Build and copy plugin files into your synced Obsidian vault.
 * Syncthing / Obsidian Sync will propagate to phone and tablet automatically.
 *
 * Override target:
 *   set OBSIDIAN_VAULT_PLUGIN_DIR=C:\path\to\vault\.obsidian\plugins\remember-cursor-position-enhanced
 *   npm run deploy
 */

import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const defaultTarget =
	process.env.OBSIDIAN_VAULT_PLUGIN_DIR ??
	'C:\\notes1\\.obsidian\\plugins\\remember-cursor-position-enhanced';

const files = ['main.js', 'manifest.json', 'LICENSE'];

console.log('Building plugin...');
execSync('npm run build', { cwd: root, stdio: 'inherit' });

const target = resolve(defaultTarget);
mkdirSync(target, { recursive: true });

for (const file of files) {
	const src = join(root, file);
	if (!existsSync(src)) {
		console.error(`Missing ${file} — build may have failed.`);
		process.exit(1);
	}
	copyFileSync(src, join(target, file));
	console.log(`Copied ${file} → ${target}`);
}

console.log('\nDone. Syncthing will push these files to your other devices.');
console.log('On each device: reload Obsidian once (Ctrl+R on desktop, restart app on mobile).');
