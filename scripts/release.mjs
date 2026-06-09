/**
 * Build plugin and copy release assets into ./release/ for GitHub upload.
 *
 * After running:
 *   1. Go to GitHub → Releases → Draft a new release
 *   2. Tag: must match manifest.json version (e.g. 2.0.0)
 *   3. Upload everything in ./release/
 *
 * Or with GitHub CLI (after gh auth login):
 *   gh release create 2.0.0 ./release/* --title 2.0.0
 */

import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const outDir = join(root, 'release');
const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));

const files = ['main.js', 'manifest.json', 'versions.json', 'LICENSE'];

console.log(`Building release ${manifest.version}...`);
execSync('npm run build', { cwd: root, stdio: 'inherit' });

if (existsSync(outDir)) {
	rmSync(outDir, { recursive: true });
}
mkdirSync(outDir, { recursive: true });

for (const file of files) {
	const src = join(root, file);
	if (!existsSync(src)) {
		console.error(`Missing ${file}`);
		process.exit(1);
	}
	copyFileSync(src, join(outDir, file));
	console.log(`  ${file}`);
}

console.log(`\nRelease assets ready in: ${outDir}`);
console.log(`\nGitHub release tag MUST be exactly: ${manifest.version}`);
console.log(`Repository URL for BRAT:\n  https://github.com/t-node/obsidian-remember-cursor-position-enhanced`);
