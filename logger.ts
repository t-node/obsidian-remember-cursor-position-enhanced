import type { EphemeralState } from './state-logic';

export type LogCategory =
	| 'LOAD'
	| 'SAVE'
	| 'RESTORE'
	| 'FLUSH'
	| 'SYNC'
	| 'MIGRATE'
	| 'EVENT'
	| 'STATE'
	| 'SETTINGS'
	| 'ERROR';

export interface LoggerOptions {
	enabled: boolean;
	logToFile: boolean;
	logFilePath: string;
	deviceLabel?: string;
	writeFile: (path: string, content: string) => Promise<void>;
	readFile: (path: string) => Promise<string>;
	exists: (path: string) => Promise<boolean>;
}

const LOG_PREFIX = 'RCP-E';
const MAX_LOG_BYTES = 512_000;
export const LOG_DIR = 'rcp-enhanced-logs';

/** Paths that must never be written — they cause Syncthing conflicts when shared across devices. */
export function isForbiddenSharedLogPath(path: string): boolean {
	const file = path.replace(/\\/g, '/').split('/').pop() ?? path;
	if (file === 'debug.log') return true;
	if (file === 'rcp-enhanced-debug.log') return true;
	if (file.startsWith('rcp-enhanced-debug.sync-conflict')) return true;
	if (file.startsWith('debug.sync-conflict')) return true;
	if (file.startsWith('~syncthing~') && file.includes('rcp-enhanced-debug')) return true;
	return false;
}

/** Only per-device files under rcp-enhanced-logs/ are allowed (never a shared vault-root log). */
export function isPerDeviceLogPath(path: string): boolean {
	const normalized = path.replace(/\\/g, '/');
	return (
		normalized.startsWith(`${LOG_DIR}/`) &&
		normalized.endsWith('.log') &&
		!normalized.includes('sync-conflict')
	);
}

export function summarizeState(state: EphemeralState | null | undefined): Record<string, unknown> {
	if (!state) return { empty: true };
	return {
		filePath: state.filePath,
		scroll: state.scroll,
		cursorFrom: state.cursor?.from,
		cursorTo: state.cursor?.to,
		lastModified: state.lastModified,
	};
}

export class PluginLogger {
	private buffer: string[] = [];
	private flushTimer: number | null = null;

	constructor(private getOptions: () => LoggerOptions) {}

	debug(category: LogCategory, message: string, data?: Record<string, unknown>): void {
		this.log('DEBUG', category, message, data);
	}

	info(category: LogCategory, message: string, data?: Record<string, unknown>): void {
		this.log('INFO', category, message, data);
	}

	warn(category: LogCategory, message: string, data?: Record<string, unknown>): void {
		this.log('WARN', category, message, data);
	}

	error(category: LogCategory, message: string, error?: unknown, data?: Record<string, unknown>): void {
		const errData: Record<string, unknown> = { ...data };
		if (error instanceof Error) {
			errData.errorName = error.name;
			errData.errorMessage = error.message;
			errData.errorStack = error.stack;
		} else if (error !== undefined) {
			errData.error = String(error);
		}
		this.log('ERROR', category, message, errData, true);
	}

	private log(
		level: 'DEBUG' | 'INFO' | 'WARN' | 'ERROR',
		category: LogCategory,
		message: string,
		data?: Record<string, unknown>,
		force = false
	): void {
		const opts = this.getOptions();
		if (!force && !opts.enabled && level !== 'ERROR') return;

		const ts = new Date().toISOString();
		const deviceTag = opts.deviceLabel ? `[${opts.deviceLabel}]` : '';
		const line = data
			? `[${LOG_PREFIX}]${deviceTag}[${ts}][${level}][${category}] ${message} | ${JSON.stringify(data)}`
			: `[${LOG_PREFIX}]${deviceTag}[${ts}][${level}][${category}] ${message}`;

		if (level === 'ERROR') console.error(line);
		else if (level === 'WARN') console.warn(line);
		else console.log(line);

		if (opts.logToFile && (opts.enabled || level === 'ERROR')) {
			this.buffer.push(line);
			this.scheduleFlush();
		}
	}

	private scheduleFlush(): void {
		if (this.flushTimer != null) return;
		this.flushTimer = window.setTimeout(() => {
			this.flushTimer = null;
			void this.flushToFile();
		}, 250);
	}

	async flushToFile(): Promise<void> {
		const opts = this.getOptions();
		if (!opts.logToFile || this.buffer.length === 0) return;

		const lines = this.buffer.splice(0);
		await this.writeLines(opts.logFilePath, lines, opts);
	}

	private async writeLines(
		path: string,
		lines: string[],
		opts: LoggerOptions
	): Promise<void> {
		if (isForbiddenSharedLogPath(path)) {
			console.error(
				`[${LOG_PREFIX}] Blocked write to shared log path (Syncthing conflict risk): ${path}. ` +
				`Use ${LOG_DIR}/YourDeviceName-id.log instead.`
			);
			return;
		}
		if (!isPerDeviceLogPath(path)) {
			console.error(
				`[${LOG_PREFIX}] Blocked write outside per-device log folder: ${path}. ` +
				`Logs must live in ${LOG_DIR}/ only.`
			);
			return;
		}

		try {
			let existing = '';
			if (await opts.exists(path)) {
				existing = await opts.readFile(path);
			}
			let combined = existing + lines.join('\n') + '\n';
			if (combined.length > MAX_LOG_BYTES) {
				combined = combined.slice(combined.length - MAX_LOG_BYTES);
				const firstNewline = combined.indexOf('\n');
				if (firstNewline >= 0) {
					combined = '...[truncated]...\n' + combined.slice(firstNewline + 1);
				}
			}
			await opts.writeFile(path, combined);
		} catch (e) {
			console.error(`[${LOG_PREFIX}] Failed to write debug log file at ${path}`, e);
		}
	}

	/** Create log files immediately with a header line (call right after plugin starts). */
	async bootstrap(headerExtra?: Record<string, unknown>): Promise<void> {
		const opts = this.getOptions();
		if (!opts.logToFile) return;

		const suffix = headerExtra ? ` | ${JSON.stringify(headerExtra)}` : '';
		const deviceTag = opts.deviceLabel ? `[${opts.deviceLabel}]` : '';
		const header =
			`[${LOG_PREFIX}]${deviceTag}[${new Date().toISOString()}][INFO][LOAD] Debug log initialized${suffix}\n`;

		try {
			if (!(await opts.exists(opts.logFilePath))) {
				await opts.writeFile(opts.logFilePath, header);
			}
		} catch (e) {
			console.error(`[${LOG_PREFIX}] Failed to bootstrap log at ${opts.logFilePath}`, e);
		}
	}

	async clearLogFile(): Promise<void> {
		const opts = this.getOptions();
		if (await opts.exists(opts.logFilePath)) {
			await opts.writeFile(opts.logFilePath, '');
		}
		this.buffer = [];
	}

	async readLogFile(): Promise<string> {
		const opts = this.getOptions();
		if (await opts.exists(opts.logFilePath)) {
			return opts.readFile(opts.logFilePath);
		}
		return '';
	}
}
