import {
	App,
	Plugin,
	PluginSettingTab,
	Setting,
	MarkdownView,
	TAbstractFile,
	Editor,
	TFile,
	Platform,
	debounce,
	Debouncer,
	Notice,
} from 'obsidian';
import {
	EphemeralState,
	getFileHash,
	isStateFilePath as isStateFilePathForDir,
	isIgnorableStateListEntry,
	isValidState,
	isEphemeralStatesEquals,
	isRegressiveScrollSave,
	isWeakDefaultScrollSave,
	isWeakTopOfNoteState,
	analyzeMergeForNote,
	explainApplyRejection,
	shouldApplyMergedState,
	shouldWatchForRemoteState,
	isOwnDeviceStateFile,
	isDeviceStoreFileName,
	getDeviceIdFromStorePath,
	findNearestHeadingLine,
	getAnchorLineFromState,
} from './state-logic';
import {
	createEmptyDeviceStore,
	collectTaggedStatesForNote,
	getDeviceStorePath,
	parseDeviceStoreJson,
	reapStateConflicts,
	migrateLegacyFilesToDeviceStores,
	migrateStateDirBetween,
	RECOMMENDED_STATE_DIR,
	pruneDeviceStore,
	upsertNoteInStore,
	type DeviceStateStore,
	type StateFileAdapter,
} from './device-store';
import { PluginLogger, summarizeState, LOG_DIR as LOGGER_LOG_DIR, isForbiddenSharedLogPath } from './logger';

interface PluginSettings {
	stateDir: string;
	delayAfterFileOpening: number;
	saveDebounceMs: number;
	reloadOnExternalChange: boolean;
	pruneOrphans: boolean;
	maxAgeDays: number;
	maxCount: number;
	debugLogging: boolean;
	logToFile: boolean;
	/** Add Syncthing .stignore rules so legacy shared logs never sync (prevents conflicts) */
	syncthingIgnoreLegacyLogs: boolean;
	/** Human-readable label for this device (used in log filename and log lines) */
	deviceName?: string;
	/** Stable per-install id so each device writes its own sync-safe log file */
	deviceId?: string;
	/** Minimize save delay + periodic flush for fastest practical cross-device sync */
	aggressiveCrossDeviceSync: boolean;
	/** @deprecated migrated to stateDir */
	dbFileName?: string;
}

const DEFAULT_SAVE_DEBOUNCE_MS = 200;
const AGGRESSIVE_SAVE_DEBOUNCE_MS = 150;
const AGGRESSIVE_PERIODIC_FLUSH_MS = 2000;
const RESTORE_FALLBACK_MS = 350;
const RESTORE_GRACE_MS = 2000;
const SYNC_RETRY_RESTORE_MS = 3000;
const AGGRESSIVE_SYNC_RETRY_RESTORE_MS = 1500;
const CROSS_DEVICE_SYNC_WATCH_MS = 60000;
const SYNC_RETRY_DELAYS_AGGRESSIVE = [1500, 4000, 8000, 15000, 30000, 60000];
const SYNC_RETRY_DELAYS_NORMAL = [3000, 7000, 12000, 20000, 45000, 60000];
const LEGACY_DB_FILENAME = '.obsidian/plugins/remember-cursor-position/cursor-positions.json';

const DEFAULT_SETTINGS: PluginSettings = {
	stateDir: '',
	delayAfterFileOpening: 100,
	saveDebounceMs: DEFAULT_SAVE_DEBOUNCE_MS,
	reloadOnExternalChange: true,
	pruneOrphans: false,
	maxAgeDays: 0,
	maxCount: 0,
	debugLogging: true,
	logToFile: true,
	syncthingIgnoreLegacyLogs: true,
	aggressiveCrossDeviceSync: true,
};

const LOG_DIR = LOGGER_LOG_DIR;
const LOCAL_DEVICE_ID_FILE = '.device-id.local.json';
const STIGNORE_MARKER_START = '# RCP-E legacy log ignore (Syncthing — auto-managed, prevents sync conflicts)';
const STIGNORE_MARKER_END = '# END RCP-E legacy log ignore';
const STIGNORE_LEGACY_LOG_RULES = [
	'rcp-enhanced-debug.log',
	'rcp-enhanced-debug.sync-conflict*',
	'~syncthing~rcp-enhanced-debug*',
	'.obsidian/plugins/remember-cursor-position-enhanced/debug.log',
	'.obsidian/plugins/remember-cursor-position-enhanced/debug.sync-conflict*',
];
const STIGNORE_LOCAL_MARKER_START = '# RCP-E per-device local files (Syncthing — never sync between devices)';
const STIGNORE_LOCAL_MARKER_END = '# END RCP-E per-device local files';
const STIGNORE_LOCAL_RULES = [
	'.obsidian/plugins/remember-cursor-position-enhanced/.device-id.local.json',
	'rcp-enhanced-logs',
	'rcp-enhanced-logs/**',
];
const STIGNORE_VAULT_MARKER_START = '# RCP-E vault noise ignore (Syncthing — auto-managed)';
const STIGNORE_VAULT_MARKER_END = '# END RCP-E vault noise ignore';
const STIGNORE_VAULT_RULES = [
	'.obsidian/workspace.json',
	'.obsidian/workspace-mobile.json',
	'.obsidian/workspaces.json',
	'.obsidian/workspace.json.sync-conflict*',
	'.obsidian/workspace-mobile.json.sync-conflict*',
	'.obsidian/workspaces.json.sync-conflict*',
	'~syncthing~.obsidian/workspace*',
	'~syncthing~.obsidian/workspaces*',
	'.obsidian/cache',
	'.obsidian/cache/**',
	'.trash',
	'.trash/**',
	'.obsidian/plugins/remember-cursor-position-enhanced/states/*.sync-conflict*',
	'.obsidian/plugins/remember-cursor-position-enhanced/states/~syncthing~*',
	'**/*.sync-conflict*',
	'**/~syncthing~*.tmp',
];
const STIGNORE_PLUGIN_CODE_MARKER_START = '# RCP-E plugin code (deploy per device — do not sync with state)';
const STIGNORE_PLUGIN_CODE_MARKER_END = '# END RCP-E plugin code';
const STIGNORE_PLUGIN_CODE_RULES = [
	'.obsidian/plugins/remember-cursor-position-enhanced/main.js',
	'.obsidian/plugins/remember-cursor-position-enhanced/manifest.json',
	'.obsidian/plugins/remember-cursor-position-enhanced/main.js.sync-conflict*',
	'.obsidian/plugins/remember-cursor-position-enhanced/manifest.json.sync-conflict*',
	'~syncthing~.obsidian/plugins/remember-cursor-position-enhanced/main.js*',
	'~syncthing~.obsidian/plugins/remember-cursor-position-enhanced/manifest.json*',
];
const LEGACY_LOG_GUARD_MS = 5000;

export default class RememberCursorPosition extends Plugin {
	settings: PluginSettings;
	logger: PluginLogger;
	lastEphemeralState: EphemeralState = {};
	lastLoadedFileName = '';
	loadingFile = false;
	reloadingState = false;
	scrollListenersAttached = false;
	debouncedSave: Debouncer<[string, EphemeralState], void>;
	pendingSavePath: string | null = null;
	pendingSaveState: EphemeralState | null = null;
	restoreGraceUntil = 0;
	crossDeviceSyncWatchUntil = new Map<string, number>();
	syncRetryRestoreTimers: number[] = [];
	pluginUpdateNoticeShown = false;
	legacyLogGuardTimer: number | null = null;
	legacyLogGuardInterval: number | null = null;
	periodicFlushInterval: number | null = null;
	ownDeviceStoreCache: DeviceStateStore | null = null;
	remoteDeviceStoresCache = new Map<string, DeviceStateStore>();
	/** Last seen storeRevision per remote device — detects LiveSync delivery without vault modify events. */
	remoteStoreRevisionSnapshot = new Map<string, number>();
	lastMergeAnalysis: { notePath: string; winnerDeviceId: string | null; candidates: import('./state-logic').MergeCandidateSummary[] } | null = null;

	getLogDirPath(): string {
		return LOG_DIR;
	}

	getDevicePlatformLabel(): string {
		if (Platform.isIosApp) return 'ios';
		if (Platform.isAndroidApp) return 'android';
		if (Platform.isDesktopApp) return 'desktop';
		if (Platform.isMobile) return 'mobile';
		return 'unknown';
	}

	getDefaultDeviceName(): string {
		if (Platform.isAndroidApp) {
			return Platform.isTablet ? 'Android Tablet' : 'Android Phone';
		}
		if (Platform.isIosApp) {
			return Platform.isTablet ? 'iPad' : 'iPhone';
		}
		if (Platform.isDesktopApp) {
			if (Platform.isWin) return 'Windows Desktop';
			if (Platform.isMacOS) return 'Mac Desktop';
			if (Platform.isLinux) return 'Linux Desktop';
			return 'Desktop';
		}
		return 'Obsidian Device';
	}

	getDeviceLabel(): string {
		const name = this.settings?.deviceName?.trim();
		return name || this.getDefaultDeviceName();
	}

	private sanitizeForLogFilename(name: string): string {
		const slug = name
			.trim()
			.replace(/[^a-zA-Z0-9]+/g, '-')
			.replace(/^-+|-+$/g, '')
			.slice(0, 32);
		return slug || 'Device';
	}

	getLogFilePath(): string {
		const nameSlug = this.sanitizeForLogFilename(this.getDeviceLabel());
		const deviceId = (this.settings?.deviceId ?? 'unknown')
			.replace(/[^a-z0-9]/gi, '')
			.slice(0, 8);
		// Unique per device: {DeviceName}-{deviceId}.log — never a shared filename
		return `${LOG_DIR}/${nameSlug}-${deviceId}.log`;
	}

	private createSafeLogWriter(): (path: string, content: string) => Promise<void> {
		const allowedPath = () => this.getLogFilePath();
		return async (path, content) => {
			if (path !== allowedPath()) {
				console.error(
					`[RCP-E] Blocked unexpected log write to ${path}. ` +
					`Only this device file is allowed: ${allowedPath()}`
				);
				return;
			}
			await this.app.vault.adapter.write(path, content);
		};
	}

	private async ensureLogDirectory(): Promise<void> {
		const dir = this.getLogDirPath();
		if (!(await this.app.vault.adapter.exists(dir))) {
			await this.app.vault.adapter.mkdir(dir);
		}
	}

	initLogger(): void {
		this.logger = new PluginLogger(() => ({
			enabled: this.settings?.debugLogging ?? true,
			logToFile: this.settings?.logToFile ?? true,
			logFilePath: this.getLogFilePath(),
			deviceLabel: this.getDeviceLabel(),
			writeFile: (path, content) => this.createSafeLogWriter()(path, content),
			readFile: (path) => this.app.vault.adapter.read(path),
			exists: (path) => this.app.vault.adapter.exists(path),
		}));
	}

	async onload() {
		try {
			await this.loadSettings();
			const legacyLogsRemoved = await this.cleanupLegacyPluginDebugLogs();
			this.initLogger();
			await this.ensureLogDirectory();
			if (legacyLogsRemoved > 0) {
				this.logger.info('LOAD', 'Removed legacy shared debug logs on startup', {
					removed: legacyLogsRemoved,
					perDeviceLogDir: this.getLogDirPath(),
					thisDeviceLog: this.getLogFilePath(),
				});
			}
			await this.logger.bootstrap({
				deviceName: this.getDeviceLabel(),
				platform: this.getDevicePlatformLabel(),
				deviceId: this.settings.deviceId,
				logFile: this.getLogFilePath(),
				pluginVersion: this.manifest.version,
			});

			this.logger.info('LOAD', 'Plugin onload started', {
				pluginId: this.manifest.id,
				version: this.manifest.version,
				deviceName: this.getDeviceLabel(),
				platform: this.getDevicePlatformLabel(),
				deviceId: this.settings.deviceId,
				stateDir: this.settings.stateDir,
				debugLogging: this.settings.debugLogging,
				logFile: this.getLogFilePath(),
				logDir: this.getLogDirPath(),
			});
			await this.logger.flushToFile();

			await this.ensureStateDir();

			this.debouncedSave = this.createDebouncedSave();

			await this.ensureSyncthingIgnoreRules();
			this.registerLegacyLogGuard();
			await this.runStorageMaintenance();
			await this.pruneStates();

			this.addSettingTab(new SettingTab(this.app, this));

			this.addCommand({
				id: 'show-plugin-version',
				name: 'Show plugin version',
				callback: () => {
					this.showLoadNotice();
				},
			});

			this.addCommand({
				id: 'force-restore-scroll',
				name: 'Re-restore scroll from synced devices (current note)',
				callback: () => {
					void this.forceRestoreCurrentNote();
				},
			});

			this.addCommand({
				id: 'show-debug-log',
				name: 'Show debug log path',
				callback: () => {
					void this.showDebugLogPaths();
				},
			});

			this.addCommand({
				id: 'list-device-debug-logs',
				name: 'List all device debug logs',
				callback: () => {
					void this.listDeviceDebugLogs();
				},
			});

			this.addCommand({
				id: 'build-combined-debug-log',
				name: 'Build combined debug log (all devices)',
				callback: () => {
					void this.buildCombinedDebugLog();
				},
			});

			this.addCommand({
				id: 'cleanup-legacy-debug-logs',
				name: 'Clean up legacy debug.log sync conflicts',
				callback: () => {
					void this.cleanupLegacyPluginDebugLogs(true);
				},
			});

			this.addCommand({
				id: 'open-debug-log',
				name: 'Open debug log',
				callback: () => {
					void this.openDebugLog();
				},
			});

			this.addCommand({
				id: 'clear-debug-log',
				name: 'Clear debug log',
				callback: () => {
					void this.clearDebugLog();
				},
			});

			this.addCommand({
				id: 'log-cross-device-sync-status',
				name: 'Log cross-device sync diagnostic (current note)',
				callback: () => {
					void this.logCrossDeviceSyncDiagnostic();
				},
			});

			this.registerEvent(
				this.app.workspace.on('file-open', (file) => {
					if (file) {
						this.logger.info('EVENT', 'file-open', { path: file.path });
						void this.onFileOpen(file);
					}
				})
			);

			this.registerEvent(
				this.app.workspace.on('active-leaf-change', () => {
					this.logger.debug('EVENT', 'active-leaf-change', {
						activeFile: this.app.workspace.getActiveFile()?.path,
						lastLoadedFileName: this.lastLoadedFileName,
					});
					void this.onActiveLeafChange();
				})
			);

			this.registerEvent(
				this.app.workspace.on('editor-change', () => this.checkEphemeralStateChanged())
			);

			this.registerEvent(
				this.app.workspace.on('layout-change', () => this.checkEphemeralStateChanged())
			);

			this.registerEvent(
				this.app.workspace.on('quit', () => {
					this.logger.info('EVENT', 'quit — flushing current note');
					void this.flushCurrentNote(true);
				})
			);

			this.registerEvent(
				this.app.vault.on('modify', (file) => {
					if (this.settings.reloadOnExternalChange && this.isStateFilePath(file.path)) {
						const deviceId = this.settings.deviceId ?? 'unknown';
						if (isOwnDeviceStateFile(file.path, deviceId)) {
							this.logger.debug('SYNC', 'Own state file modified — skip external reload', {
								path: file.path,
							});
							return;
						}
						this.logger.info('SYNC', 'State file modified externally', { path: file.path });
						void this.handleExternalStateChange(file.path);
					}
					const pluginManifest = `${this.manifest.dir}/manifest.json`;
					const pluginMain = `${this.manifest.dir}/main.js`;
					if (file.path === pluginManifest || file.path === pluginMain) {
						void this.checkForSyncedPluginUpdate();
					}
				})
			);

			this.registerDomEvent(document, 'visibilitychange', () => {
				if (document.visibilityState === 'hidden') {
					this.logger.info('EVENT', 'App backgrounded — flushing current note');
					void this.flushCurrentNote(true);
				}
			});

			this.registerDomEvent(window, 'blur', () => {
				this.logger.info('EVENT', 'Window blurred — flushing current note');
				void this.flushCurrentNote(true);
			});

			this.registerEvent(
				this.app.vault.on('rename', (file, oldPath) => {
					this.logger.info('EVENT', 'vault rename', { from: oldPath, to: file.path });
					void this.renameFile(file, oldPath);
				})
			);

			this.registerEvent(
				this.app.vault.on('delete', (file) => {
					this.logger.info('EVENT', 'vault delete', { path: file.path });
					void this.deleteFile(file);
				})
			);

			this.setupDOMEventListeners();
			void this.seedRemoteStoreRevisionSnapshot();
			this.applyPeriodicFlush();
			void this.restoreCurrentNote();

			this.logger.info('LOAD', 'Plugin onload completed successfully', {
				version: this.manifest.version,
				deviceId: this.settings.deviceId,
				deviceName: this.getDeviceLabel(),
				platform: this.getDevicePlatformLabel(),
				perDeviceState: true,
			});
			this.showLoadNotice();
			await this.logger.flushToFile();
		} catch (e) {
			const msg = e instanceof Error ? e.message : String(e);
			console.error('[RCP-E][LOAD] FATAL onload error:', e);
			try {
				if (this.logger) {
					this.logger.error('LOAD', 'Plugin onload FAILED', e);
					await this.logger.flushToFile();
				}
			} catch {
				// ignore secondary logging failure
			}
			throw e;
		}
	}

	showLoadNotice(): void {
		const version = this.manifest.version;
		const device = this.getDeviceLabel();
		const deviceId = this.settings.deviceId ?? 'unknown';
		const platform = this.getDevicePlatformLabel();
		const lines = [
			`RCP-E v${version} loaded`,
			`${device} (${platform}) · id ${deviceId}`,
		];
		if (this.settings.debugLogging) {
			lines.push(`Log: ${this.getLogFilePath()}`);
		}
		new Notice(lines.join('\n'), 10000);
	}

	async clearDebugLog(): Promise<void> {
		await this.logger.clearLogFile();
		this.logger.info('SETTINGS', 'Debug log cleared', {
			platform: this.getDevicePlatformLabel(),
			deviceId: this.settings.deviceId,
			logFile: this.getLogFilePath(),
		});
		await this.logger.flushToFile();
	}

	async openDebugLog(): Promise<void> {
		await this.logger.flushToFile();
		await this.openLogFile(this.getLogFilePath());
	}

	async openLogFile(path: string): Promise<void> {
		const file = this.app.vault.getAbstractFileByPath(path);
		if (file instanceof TFile) {
			await this.app.workspace.getLeaf(false).openFile(file);
			return;
		}
		new Notice(
			`Log file not found: ${path}\nEnable the plugin first, then reload Obsidian.`,
			8000
		);
	}

	async listDeviceDebugLogPaths(): Promise<string[]> {
		const dir = this.getLogDirPath();
		if (!(await this.app.vault.adapter.exists(dir))) {
			return [this.getLogFilePath()];
		}
		const listing = await this.app.vault.adapter.list(dir);
		const logs = listing.files.filter((name) => name.endsWith('.log')).sort();
		return logs.length > 0 ? logs.map((name) => `${dir}/${name}`) : [this.getLogFilePath()];
	}

	async showDebugLogPaths(): Promise<void> {
		await this.logger.flushToFile();
		const logs = await this.listDeviceDebugLogPaths();
		this.logger.info('SETTINGS', 'Debug log paths requested', {
			thisDevice: this.getLogFilePath(),
			allLogs: logs,
		});
		const lines = logs.map((p) => {
			const fileName = p.split('/').pop() ?? p;
			if (p === this.getLogFilePath()) {
				return `→ ${fileName} (${this.getDeviceLabel()} — this device)`;
			}
			const label = fileName.replace(/\.log$/i, '').replace(/-/g, ' ');
			return `  ${fileName} (${label})`;
		});
		new Notice(`RCP-E debug logs in ${this.getLogDirPath()}/:\n${lines.join('\n')}`, 12000);
	}

	async listDeviceDebugLogs(): Promise<void> {
		await this.showDebugLogPaths();
	}

	async checkForSyncedPluginUpdate(): Promise<void> {
		if (this.pluginUpdateNoticeShown) return;

		try {
			const manifestPath = `${this.manifest.dir}/manifest.json`;
			const raw = await this.app.vault.adapter.read(manifestPath);
			const disk = JSON.parse(raw) as { version?: string };

			if (!disk.version || disk.version === this.manifest.version) return;

			this.pluginUpdateNoticeShown = true;
			const reloadHint = Platform.isDesktopApp
				? 'Press Ctrl+R to reload Obsidian.'
				: 'Close and reopen Obsidian to activate.';

			this.logger.info('LOAD', 'Synced plugin update detected — reload required', {
				runningVersion: this.manifest.version,
				syncedVersion: disk.version,
			});

			new Notice(
				`RCP-E v${disk.version} synced to this device.\n${reloadHint}`,
				12000
			);
		} catch {
			// ignore read errors
		}
	}

	async cleanupLegacyPluginDebugLogs(notify = false): Promise<number> {
		let removed = 0;

		removed += await this.cleanupLegacyLogsInDir(
			this.manifest.dir,
			(name) =>
				name === 'debug.log' ||
				(name.startsWith('debug.sync-conflict') && name.endsWith('.log'))
		);

		removed += await this.cleanupLegacyLogsInDir('', (name) =>
			name === 'rcp-enhanced-debug.log' ||
			(name.startsWith('rcp-enhanced-debug.sync-conflict') && name.endsWith('.log')) ||
			(name.startsWith('~syncthing~') && name.includes('rcp-enhanced-debug'))
		);

		if (notify) {
			new Notice(
				removed > 0
					? `Removed ${removed} legacy shared log file(s).\nLogs are in ${this.getLogDirPath()}/ (one file per device).`
					: `No legacy shared log files found. Logs use ${this.getLogDirPath()}/ only.`,
				8000
			);
		}

		return removed;
	}

	private isLegacySharedLogVaultPath(path: string): boolean {
		return isForbiddenSharedLogPath(path);
	}

	private scheduleLegacyLogGuard(): void {
		if (this.legacyLogGuardTimer != null) return;
		this.legacyLogGuardTimer = window.setTimeout(() => {
			this.legacyLogGuardTimer = null;
			void this.cleanupLegacyPluginDebugLogs();
		}, LEGACY_LOG_GUARD_MS);
	}

	registerLegacyLogGuard(): void {
		this.registerEvent(
			this.app.vault.on('create', (file) => {
				if (file instanceof TFile && this.isLegacySharedLogVaultPath(file.path)) {
					this.scheduleLegacyLogGuard();
				}
			})
		);

		this.registerEvent(
			this.app.vault.on('modify', (file) => {
				if (file instanceof TFile && this.isLegacySharedLogVaultPath(file.path)) {
					this.scheduleLegacyLogGuard();
				}
			})
		);

		this.legacyLogGuardInterval = window.setInterval(() => {
			void this.cleanupLegacyPluginDebugLogs();
		}, 120_000);
	}

	async ensureSyncthingIgnoreRules(): Promise<void> {
		if (!this.settings.syncthingIgnoreLegacyLogs) return;

		try {
			await this.ensureStignoreBlock(
				STIGNORE_MARKER_START,
				STIGNORE_MARKER_END,
				STIGNORE_LEGACY_LOG_RULES
			);
			await this.ensureStignoreBlock(
				STIGNORE_LOCAL_MARKER_START,
				STIGNORE_LOCAL_MARKER_END,
				STIGNORE_LOCAL_RULES
			);
			await this.ensureStignoreBlock(
				STIGNORE_VAULT_MARKER_START,
				STIGNORE_VAULT_MARKER_END,
				STIGNORE_VAULT_RULES
			);
			await this.ensureStignoreBlock(
				STIGNORE_PLUGIN_CODE_MARKER_START,
				STIGNORE_PLUGIN_CODE_MARKER_END,
				STIGNORE_PLUGIN_CODE_RULES
			);
		} catch (e) {
			console.warn('[RCP-E] Could not update .stignore for Syncthing:', e);
		}
	}

	private async ensureStignoreBlock(
		markerStart: string,
		markerEnd: string,
		rules: string[]
	): Promise<void> {
		const stignorePath = '.stignore';
		const block = [markerStart, ...rules, markerEnd].join('\n') + '\n';

		let content = '';
		if (await this.app.vault.adapter.exists(stignorePath)) {
			content = await this.app.vault.adapter.read(stignorePath);
			if (content.includes(markerStart)) return;
			content = content.trimEnd() + '\n\n' + block;
		} else {
			content = block;
		}
		await this.app.vault.adapter.write(stignorePath, content);
	}

	private localDeviceIdPath(): string {
		return `${this.manifest.dir}/${LOCAL_DEVICE_ID_FILE}`;
	}

	/** Device id lives in a local-only file so Syncthing cannot copy one device's id to another. */
	private async loadLocalDeviceId(): Promise<string> {
		const path = this.localDeviceIdPath();
		try {
			if (await this.app.vault.adapter.exists(path)) {
				const raw = await this.app.vault.adapter.read(path);
				const parsed = JSON.parse(raw) as { deviceId?: string };
				if (parsed.deviceId) return parsed.deviceId;
			}
		} catch (e) {
			console.warn('[RCP-E] Could not read local device id', e);
		}

		const deviceId = Math.random().toString(36).slice(2, 10);
		try {
			await this.app.vault.adapter.write(
				path,
				JSON.stringify({ deviceId }, null, 2)
			);
		} catch (e) {
			console.warn('[RCP-E] Could not write local device id', e);
		}
		return deviceId;
	}

	private async cleanupLegacyLogsInDir(
		dir: string,
		matcher: (fileName: string) => boolean
	): Promise<number> {
		if (!(await this.app.vault.adapter.exists(dir))) return 0;

		const listing = await this.app.vault.adapter.list(dir);
		const toRemove = listing.files.filter(matcher);

		for (const name of toRemove) {
			const path = dir ? `${dir}/${name}` : name;
			try {
				await this.app.vault.adapter.remove(path);
			} catch (e) {
				console.warn(`[RCP-E] Failed to remove legacy log file ${path}`, e);
			}
		}

		return toRemove.length;
	}

	async buildCombinedDebugLog(): Promise<void> {
		const dir = this.getLogDirPath();
		await this.ensureLogDirectory();
		const logs = await this.listDeviceDebugLogPaths();
		const sourceLogs = logs.filter((p) => !p.includes('_COMBINED-'));

		const entries: { ts: string; line: string; source: string }[] = [];

		for (const path of sourceLogs) {
			if (!(await this.app.vault.adapter.exists(path))) continue;
			const content = await this.app.vault.adapter.read(path);
			const source = path.split('/').pop() ?? path;
			for (const line of content.split('\n')) {
				if (!line.trim()) continue;
				const tsMatch = line.match(/\[(\d{4}-\d{2}-\d{2}T[^\]]+)\]/);
				entries.push({
					ts: tsMatch?.[1] ?? '',
					line,
					source,
				});
			}
		}

		entries.sort((a, b) => a.ts.localeCompare(b.ts));

		const header =
			`# Combined RCP-E debug log — generated ${new Date().toISOString()}\n` +
			`# Sources: ${sourceLogs.map((p) => p.split('/').pop()).join(', ')}\n` +
			`# Each device writes its own file; this file merges them by timestamp for easy reading.\n\n`;

		const body = entries.map((e) => e.line).join('\n') + '\n';
		const outPath = `${dir}/_COMBINED-all-devices.log`;
		await this.app.vault.adapter.write(outPath, header + body);

		this.logger.info('SETTINGS', 'Built combined debug log', {
			outPath,
			sourceCount: sourceLogs.length,
			lineCount: entries.length,
		});
		await this.logger.flushToFile();

		new Notice(
			`Combined log written: ${outPath}\n(${entries.length} lines from ${sourceLogs.length} device log(s))`,
			8000
		);
		await this.openLogFile(outPath);
	}

	onunload() {
		for (const timer of this.syncRetryRestoreTimers) {
			window.clearTimeout(timer);
		}
		this.syncRetryRestoreTimers = [];
		if (this.legacyLogGuardTimer != null) {
			window.clearTimeout(this.legacyLogGuardTimer);
			this.legacyLogGuardTimer = null;
		}
		if (this.legacyLogGuardInterval != null) {
			window.clearInterval(this.legacyLogGuardInterval);
			this.legacyLogGuardInterval = null;
		}
		this.stopPeriodicFlush();
		if (!this.logger) return;
		this.logger.info('LOAD', 'Plugin onunload started', {
			lastLoadedFileName: this.lastLoadedFileName,
			pendingSavePath: this.pendingSavePath,
		});
		if (this.pendingSavePath && this.pendingSaveState) {
			void this.writeNoteState(this.pendingSavePath, this.pendingSaveState);
		}
		void this.flushCurrentNote(true);
		if (this.debouncedSave) {
			this.debouncedSave.cancel();
		}
		this.scrollListenersAttached = false;
		void this.logger.flushToFile();
		this.logger.info('LOAD', 'Plugin onunload completed');
	}

	getOwnDeviceStorePath(): string {
		return getDeviceStorePath(
			this.settings.stateDir,
			this.settings.deviceId ?? 'unknown'
		);
	}

	/** @deprecated v1 per-note path — use getOwnDeviceStorePath */
	getStateFilePathForNote(_notePath: string): string {
		return this.getOwnDeviceStorePath();
	}

	getStorageAdapter(): StateFileAdapter {
		return {
			listFiles: async (stateDir) => {
				if (!(await this.app.vault.adapter.exists(stateDir))) return [];
				const listing = await this.app.vault.adapter.list(stateDir);
				return (listing.files ?? []).filter((f) => !isIgnorableStateListEntry(f));
			},
			exists: (path) => this.app.vault.adapter.exists(path),
			read: (path) => this.app.vault.adapter.read(path),
			write: (path, content) => this.app.vault.adapter.write(path, content),
			remove: (path) => this.app.vault.adapter.remove(path),
		};
	}

	async runStorageMaintenance(): Promise<void> {
		const adapter = this.getStorageAdapter();
		const stateDir = this.settings.stateDir;
		const deviceId = this.settings.deviceId ?? 'unknown';

		const reap = await reapStateConflicts(stateDir, adapter);
		if (reap.merged > 0 || reap.deleted > 0) {
			this.logger.info('SYNC', 'Conflict reaper finished', { ...reap });
		}
		for (const err of reap.errors) {
			this.logger.warn('SYNC', 'Conflict reaper error', { err });
		}

		const migration = await migrateLegacyFilesToDeviceStores(stateDir, deviceId, adapter);
		if (migration.notesMigrated > 0) {
			this.logger.info('MIGRATE', 'Legacy per-note files migrated to device stores', { ...migration });
		}

		const legacyPluginStateDir = this.manifest.dir + '/states';
		if (stateDir === RECOMMENDED_STATE_DIR && legacyPluginStateDir !== stateDir) {
			const dirMigration = await migrateStateDirBetween(legacyPluginStateDir, stateDir, adapter);
			if (dirMigration.filesCopied > 0 || dirMigration.filesMerged > 0) {
				this.logger.info('MIGRATE', 'Moved device stores to cursor-state/', { ...dirMigration });
			}
			for (const err of dirMigration.errors) {
				this.logger.warn('MIGRATE', 'State dir migration error', { err });
			}
		}

		this.ownDeviceStoreCache = null;
		this.remoteDeviceStoresCache.clear();
	}

	async loadOwnDeviceStore(): Promise<DeviceStateStore> {
		if (this.ownDeviceStoreCache) return this.ownDeviceStoreCache;
		const deviceId = this.settings.deviceId ?? 'unknown';
		const path = getDeviceStorePath(this.settings.stateDir, deviceId);
		if (await this.app.vault.adapter.exists(path)) {
			const raw = await this.app.vault.adapter.read(path);
			const parsed = parseDeviceStoreJson(raw);
			if (parsed) {
				this.ownDeviceStoreCache = parsed;
				return parsed;
			}
		}
		const empty = createEmptyDeviceStore(deviceId);
		this.ownDeviceStoreCache = empty;
		return empty;
	}

	async loadRemoteDeviceStores(): Promise<DeviceStateStore[]> {
		const ownId = this.settings.deviceId ?? 'unknown';
		const adapter = this.getStorageAdapter();
		const files = await adapter.listFiles(this.settings.stateDir);
		const stores: DeviceStateStore[] = [];
		const ownStore = await this.loadOwnDeviceStore();
		stores.push(ownStore);

		for (const filePath of files) {
			const name = filePath.split('/').pop() ?? '';
			if (!isDeviceStoreFileName(name)) continue;
			const id = name.replace(/\.json$/i, '');
			if (id === ownId) continue;
			const cached = this.remoteDeviceStoresCache.get(id);
			if (cached) {
				stores.push(cached);
				continue;
			}
			const raw = await adapter.read(filePath);
			const parsed = parseDeviceStoreJson(raw);
			if (parsed) {
				this.remoteDeviceStoresCache.set(id, parsed);
				stores.push(parsed);
			}
		}
		return stores;
	}

	async persistOwnDeviceStore(store: DeviceStateStore): Promise<void> {
		await this.ensureStateDir();
		const path = getDeviceStorePath(this.settings.stateDir, store.deviceId);
		await this.app.vault.adapter.write(path, JSON.stringify(store));
		this.ownDeviceStoreCache = store;
	}

	setCrossDeviceSyncWatch(notePath: string): void {
		this.crossDeviceSyncWatchUntil.set(notePath, Date.now() + CROSS_DEVICE_SYNC_WATCH_MS);
		this.logger.warn('SYNC', 'Watching for remote device state — Syncthing may still be delivering', {
			notePath,
			watchMs: CROSS_DEVICE_SYNC_WATCH_MS,
			deviceId: this.settings.deviceId,
		});
	}

	clearCrossDeviceSyncWatch(notePath: string): void {
		this.crossDeviceSyncWatchUntil.delete(notePath);
	}

	isWatchingForRemoteSync(notePath: string): boolean {
		const until = this.crossDeviceSyncWatchUntil.get(notePath) ?? 0;
		if (until <= Date.now()) {
			this.crossDeviceSyncWatchUntil.delete(notePath);
			return false;
		}
		return true;
	}

	maybeSetCrossDeviceSyncWatch(
		notePath: string,
		stateFiles: string[],
		merged: EphemeralState | null
	): void {
		const deviceId = this.settings.deviceId ?? 'unknown';
		if (shouldWatchForRemoteState(stateFiles, deviceId, merged)) {
			this.setCrossDeviceSyncWatch(notePath);
		}
	}

	async listDeviceStoreFiles(): Promise<string[]> {
		const adapter = this.getStorageAdapter();
		const files = await adapter.listFiles(this.settings.stateDir);
		return files.filter((f) => {
			const name = f.split('/').pop() ?? '';
			return isDeviceStoreFileName(name);
		});
	}

	async listStateFilesForNote(_notePath: string): Promise<string[]> {
		return this.listDeviceStoreFiles();
	}

	async readMergedNoteState(
		notePath: string,
		options?: { respectLinkFlash?: boolean }
	): Promise<EphemeralState | null> {
		const respectLinkFlash = options?.respectLinkFlash ?? false;
		const stateFiles = await this.listDeviceStoreFiles();
		const stores = await this.loadRemoteDeviceStores();
		const tagged = collectTaggedStatesForNote(stores, notePath);

		if (tagged.length === 0) {
			this.logger.debug('RESTORE', 'No state for note in device stores', {
				notePath,
				deviceStoreCount: stateFiles.length,
				noteHash: getFileHash(notePath),
			});
			this.maybeSetCrossDeviceSyncWatch(notePath, stateFiles, null);
			return null;
		}

		const analysis = analyzeMergeForNote(tagged, {
			onSkewDetected: (message) => this.logger.warn('SYNC', 'Clock skew detected', { message, notePath }),
		});
		this.lastMergeAnalysis = {
			notePath,
			winnerDeviceId: analysis.winnerDeviceId,
			candidates: analysis.candidates,
		};

		const merged = analysis.merged;
		if (!merged) {
			return null;
		}

		const logLevel = tagged.length > 1 ? 'info' : 'debug';
		const mergeLog = {
			notePath,
			noteHash: getFileHash(notePath),
			winnerDeviceId: analysis.winnerDeviceId,
			ownDeviceId: this.settings.deviceId,
			candidateCount: analysis.candidates.length,
			candidates: analysis.candidates,
			weakScrollOverride: analysis.weakScrollOverride,
			winner: summarizeState(merged),
		};
		if (logLevel === 'info') {
			this.logger.info('SYNC', 'Merge winner for note', mergeLog);
		} else {
			this.logger.debug('RESTORE', 'Merged state from device stores', mergeLog);
		}

		if (!merged.filePath) merged.filePath = notePath;

		if (respectLinkFlash && this.app.workspace.containerEl.querySelector('.is-flashing')) {
			this.logger.info('RESTORE', 'Skipped restore — link flash active', { notePath });
			return null;
		}

		this.maybeSetCrossDeviceSyncWatch(notePath, stateFiles, merged);
		return merged;
	}

	isStateFilePath(path: string): boolean {
		return isStateFilePathForDir(this.settings.stateDir, path);
	}

	async ensureStateDir(): Promise<void> {
		if (!(await this.app.vault.adapter.exists(this.settings.stateDir))) {
			this.logger.info('SETTINGS', 'Creating state directory', { path: this.settings.stateDir });
			await this.app.vault.adapter.mkdir(this.settings.stateDir);
		}
	}

	async readNoteState(notePath: string): Promise<EphemeralState | null> {
		return this.readMergedNoteState(notePath, { respectLinkFlash: true });
	}

	async readStateFile(stateFilePath: string): Promise<EphemeralState | null> {
		try {
			if (!(await this.app.vault.adapter.exists(stateFilePath))) {
				this.logger.debug('SYNC', 'State file not found', { stateFilePath });
				return null;
			}
			const data = await this.app.vault.adapter.read(stateFilePath);
			const store = parseDeviceStoreJson(data);
			if (store) {
				this.logger.debug('SYNC', 'Read device store file', {
					stateFilePath,
					deviceId: store.deviceId,
					noteCount: Object.keys(store.notes).length,
					storeRevision: store.storeRevision,
				});
				const ownId = this.settings.deviceId ?? 'unknown';
				if (store.deviceId === ownId) {
					this.ownDeviceStoreCache = store;
				} else {
					this.remoteDeviceStoresCache.set(store.deviceId, store);
				}
				return null;
			}
			const parsed = JSON.parse(data) as EphemeralState;
			this.logger.debug('SYNC', 'Read legacy state file', {
				stateFilePath,
				state: summarizeState(parsed),
			});
			return parsed;
		} catch (e) {
			this.logger.error('SYNC', 'Failed to read state file', e, { stateFilePath });
			return null;
		}
	}

	async writeNoteState(notePath: string, state: EphemeralState): Promise<void> {
		const stateFilePath = this.getOwnDeviceStorePath();
		try {
			await this.ensureStateDir();

			const existing = await this.readMergedNoteState(notePath);
			const saveTimestamp = state.lastModified ?? Date.now();
			const stateToSave: EphemeralState = {
				...state,
				filePath: notePath,
				lastModified: saveTimestamp,
			};

			if (existing && (existing.lastModified ?? 0) > saveTimestamp) {
				this.logger.warn('SAVE', 'Skip write — merged disk state is newer (likely synced from another device)', {
					notePath,
					diskLastModified: existing.lastModified,
					proposedLastModified: saveTimestamp,
					diskScroll: existing.scroll,
					proposedScroll: stateToSave.scroll,
					deviceFile: stateFilePath,
				});
				if (notePath === this.lastLoadedFileName) {
					this.lastEphemeralState = existing;
				}
				return;
			}

			if (existing && isWeakDefaultScrollSave(stateToSave, existing)) {
				this.logger.warn('SAVE', 'Skip write — weak scroll-0 save would clobber real position on disk', {
					notePath,
					diskScroll: existing.scroll,
					proposedScroll: stateToSave.scroll,
					deviceFile: stateFilePath,
				});
				return;
			}

			if (
				isWeakTopOfNoteState(stateToSave) &&
				this.isWatchingForRemoteSync(notePath)
			) {
				this.logger.warn('SAVE', 'Skip write — weak top-of-note save while waiting for remote device state', {
					notePath,
					proposedScroll: stateToSave.scroll,
					watchMsRemaining:
						(this.crossDeviceSyncWatchUntil.get(notePath) ?? 0) - Date.now(),
					deviceFile: stateFilePath,
				});
				return;
			}

			if (
				existing &&
				Date.now() < this.restoreGraceUntil &&
				isRegressiveScrollSave(stateToSave, existing)
			) {
				this.logger.warn('SAVE', 'Skip write — regressive scroll during restore grace (editor may not be ready)', {
					notePath,
					diskScroll: existing.scroll,
					proposedScroll: stateToSave.scroll,
					graceMsRemaining: this.restoreGraceUntil - Date.now(),
				});
				return;
			}

			if (existing && isRegressiveScrollSave(stateToSave, existing)) {
				this.logger.warn('SAVE', 'Skip write — regressive scroll vs merged disk state', {
					notePath,
					diskScroll: existing.scroll,
					proposedScroll: stateToSave.scroll,
					deviceFile: stateFilePath,
				});
				return;
			}

			let store = await this.loadOwnDeviceStore();
			const noteHash = getFileHash(notePath);
			const existingOwn = store.notes[noteHash];
			if (existingOwn && isEphemeralStatesEquals(existingOwn, stateToSave)) {
				this.logger.debug('SAVE', 'Skip write — own device entry unchanged', {
					notePath,
					noteHash,
					scroll: stateToSave.scroll,
					cursorLine: stateToSave.cursor?.from.line,
				});
				if (notePath === this.lastLoadedFileName) {
					this.lastEphemeralState = { ...existingOwn, filePath: notePath };
				}
				return;
			}

			store = upsertNoteInStore(store, notePath, stateToSave);
			await this.persistOwnDeviceStore(store);

			this.logger.info('SAVE', 'Wrote state to device store', {
				notePath,
				stateFilePath,
				deviceId: this.settings.deviceId,
				platform: this.getDevicePlatformLabel(),
				storeRevision: store.storeRevision,
				noteHash: getFileHash(notePath),
				state: summarizeState(stateToSave),
			});

			if ((stateToSave.scroll ?? 0) > 20) {
				this.clearCrossDeviceSyncWatch(notePath);
			}

			if (notePath === this.lastLoadedFileName) {
				this.lastEphemeralState = stateToSave;
			}

			if (this.pendingSavePath === notePath) {
				this.pendingSavePath = null;
				this.pendingSaveState = null;
			}
		} catch (e) {
			this.logger.error('SAVE', 'Failed to write note state', e, { notePath, stateFilePath });
		}
	}

	async deleteNoteState(notePath: string): Promise<void> {
		const hash = getFileHash(notePath);
		const store = await this.loadOwnDeviceStore();
		if (!store.notes[hash]) return;
		const { [hash]: _removed, ...rest } = store.notes;
		const updated = { ...store, notes: rest, storeRevision: store.storeRevision + 1 };
		await this.persistOwnDeviceStore(updated);
		this.logger.info('SAVE', 'Removed note from device store', { notePath, hash });
	}

	async migrateLegacyDbIfNeeded(): Promise<void> {
		const legacyPaths = [
			this.settings.dbFileName,
			LEGACY_DB_FILENAME,
			this.manifest.dir + '/cursor-positions.json',
		].filter((p): p is string => !!p);

		this.logger.debug('MIGRATE', 'Checking legacy databases', { legacyPaths });

		for (const legacyPath of legacyPaths) {
			if (!(await this.app.vault.adapter.exists(legacyPath))) continue;

			try {
				this.logger.info('MIGRATE', 'Found legacy database', { legacyPath });
				const data = await this.app.vault.adapter.read(legacyPath);
				const db = JSON.parse(data) as { [file_path: string]: EphemeralState };
				let migrated = 0;

				for (const [notePath, state] of Object.entries(db)) {
					if (!isValidState(state)) continue;
					const existing = await this.readNoteState(notePath);
					if (!existing || (state.lastModified ?? 0) > (existing.lastModified ?? 0)) {
						await this.writeNoteState(notePath, state);
						migrated++;
					}
				}

				this.logger.info('MIGRATE', 'Legacy migration complete', { legacyPath, migrated });

				if (migrated > 0) {
					const backupPath = legacyPath + '.migrated-backup';
					if (!(await this.app.vault.adapter.exists(backupPath))) {
						await this.app.vault.adapter.write(backupPath, data);
						this.logger.info('MIGRATE', 'Legacy backup written', { backupPath });
					}
				}
				break;
			} catch (e) {
				this.logger.error('MIGRATE', 'Legacy migration failed', e, { legacyPath });
			}
		}
	}

	async onFileOpen(file: TFile) {
		if (!this.shouldTrackFile(file)) {
			this.logger.debug('RESTORE', 'Skipping non-markdown file', { path: file.path, extension: file.extension });
			return;
		}

		this.logger.info('RESTORE', 'onFileOpen started', {
			path: file.path,
			previousFile: this.lastLoadedFileName,
			loadingFile: this.loadingFile,
		});

		if (this.lastLoadedFileName && this.lastLoadedFileName !== file.path) {
			this.logger.debug('FLUSH', 'Flushing previous note before open', {
				previousFile: this.lastLoadedFileName,
			});
			await this.flushNoteState(this.lastLoadedFileName, this.lastEphemeralState, true);
		}

		this.loadingFile = true;
		this.lastLoadedFileName = file.path;

		let restored = false;

		const finishRestore = (source: 'layout-change' | 'fallback-timer') => {
			if (restored) return;
			restored = true;
			this.loadingFile = false;
			this.restoreGraceUntil = Date.now() + RESTORE_GRACE_MS;
			this.app.workspace.off('layout-change', layoutChangeHandler);
			window.clearTimeout(fallbackTimer);
			this.logger.info('RESTORE', 'Restore cycle finished', {
				path: file.path,
				source,
				restoreGraceMs: RESTORE_GRACE_MS,
				syncRetryRestoreMs: this.getSyncRetryRestoreMs(),
			});
			this.scheduleSyncRetryRestore(file.path);
		};

		const layoutChangeHandler = async () => {
			const activeView = this.app.workspace.getActiveViewOfType(MarkdownView);
			if (activeView?.file?.path !== file.path) {
				this.logger.debug('RESTORE', 'layout-change skipped — file mismatch', {
					expected: file.path,
					active: activeView?.file?.path,
				});
				return;
			}

			this.logger.debug('RESTORE', 'layout-change — restoring', { path: file.path });
			await this.restoreNoteState(file.path);
			finishRestore('layout-change');
		};

		this.app.workspace.on('layout-change', layoutChangeHandler);

		const fallbackTimer = window.setTimeout(async () => {
			if (restored || this.lastLoadedFileName !== file.path) return;
			this.logger.warn('RESTORE', 'Using fallback timer — layout-change did not restore', {
				path: file.path,
				delayMs: this.settings.delayAfterFileOpening + RESTORE_FALLBACK_MS,
			});
			await this.restoreNoteState(file.path);
			finishRestore('fallback-timer');
		}, this.settings.delayAfterFileOpening + RESTORE_FALLBACK_MS);
	}

	async onActiveLeafChange() {
		const currentPath = this.app.workspace.getActiveFile()?.path;
		if (currentPath && currentPath !== this.lastLoadedFileName && this.lastLoadedFileName) {
			this.logger.debug('FLUSH', 'active-leaf-change — flushing previous note', {
				from: this.lastLoadedFileName,
				to: currentPath,
			});
			await this.flushNoteState(this.lastLoadedFileName, this.lastEphemeralState, true);
		}
		this.checkEphemeralStateChanged();
	}

	async flushCurrentNote(immediate = false) {
		const fileName = this.lastLoadedFileName;
		if (!fileName || this.loadingFile) {
			this.logger.debug('FLUSH', 'flushCurrentNote skipped', {
				fileName,
				loadingFile: this.loadingFile,
				reason: !fileName ? 'no-file' : 'loading',
			});
			return;
		}

		// Prefer live editor position — lastEphemeralState can lag behind or hold a stale restore target.
		const live = this.getEphemeralState();
		const enriched = isValidState(live) ? this.enrichStateWithAnchor(live, fileName) : null;
		let st: EphemeralState;

		if (enriched && isValidState(enriched)) {
			if (
				isValidState(this.lastEphemeralState) &&
				isEphemeralStatesEquals(enriched, this.lastEphemeralState)
			) {
				this.logger.debug('FLUSH', 'flushCurrentNote skipped — scroll/cursor unchanged', {
					notePath: fileName,
					state: summarizeState(this.lastEphemeralState),
				});
				return;
			}
			st = { ...enriched, filePath: fileName, lastModified: Date.now() };
		} else if (isValidState(this.lastEphemeralState)) {
			st = this.lastEphemeralState;
		} else {
			st = live;
		}

		this.logger.info('FLUSH', 'flushCurrentNote', {
			notePath: fileName,
			immediate,
			state: summarizeState(st),
		});
		await this.flushNoteState(fileName, st, immediate);
	}

	async flushNoteState(notePath: string | undefined, state: EphemeralState, immediate = false) {
		if (!notePath || !isValidState(state)) {
			this.logger.debug('FLUSH', 'flushNoteState skipped — invalid state', {
				notePath,
				state: summarizeState(state),
			});
			return;
		}

		this.debouncedSave.cancel();

		if (immediate) {
			this.logger.debug('FLUSH', 'Immediate write', { notePath });
			await this.writeNoteState(notePath, state);
		} else {
			this.logger.debug('FLUSH', 'Queued debounced save', { notePath });
			this.queueSave(notePath, state);
		}
	}

	queueSave(notePath: string, state: EphemeralState) {
		this.pendingSavePath = notePath;
		this.pendingSaveState = state;
		this.logger.debug('SAVE', 'queueSave', { notePath, state: summarizeState(state) });
		this.debouncedSave(notePath, state);
	}

	async writeSyncDiagnostic(event: string, data: Record<string, unknown>): Promise<void> {
		const deviceId = this.settings.deviceId ?? 'unknown';
		const path = `${this.settings.stateDir}/.diag-${deviceId}.json`;
		try {
			let events: unknown[] = [];
			if (await this.app.vault.adapter.exists(path)) {
				const raw = await this.app.vault.adapter.read(path);
				const parsed = JSON.parse(raw) as { events?: unknown[] };
				events = parsed.events ?? [];
			}
			events.push({
				ts: new Date().toISOString(),
				event,
				platform: this.getDevicePlatformLabel(),
				deviceId,
				deviceName: this.getDeviceLabel(),
				pluginVersion: this.manifest.version,
				...data,
			});
			if (events.length > 30) {
				events = events.slice(events.length - 30);
			}
			await this.app.vault.adapter.write(
				path,
				JSON.stringify({ deviceId, updated: Date.now(), events }, null, 2)
			);
		} catch (e) {
			this.logger.warn('SYNC', 'Failed to write sync diagnostic file', {
				err: e instanceof Error ? e.message : String(e),
			});
		}
	}

	async logCrossDeviceSyncDiagnostic(): Promise<void> {
		const file = this.app.workspace.getActiveFile();
		if (!file) {
			new Notice('Open a markdown note first.');
			return;
		}
		const notePath = file.path;
		await this.pollRemoteStateForActiveNote('manual-diagnostic');
		const merged = await this.readMergedNoteState(notePath);
		const editorNow = summarizeState(this.getEphemeralState());
		const payload = {
			notePath,
			noteHash: getFileHash(notePath),
			ownDeviceId: this.settings.deviceId,
			platform: this.getDevicePlatformLabel(),
			merge: this.lastMergeAnalysis,
			merged: summarizeState(merged),
			editorNow,
			applied: summarizeState(this.lastEphemeralState),
			remoteRevisions: Object.fromEntries(this.remoteStoreRevisionSnapshot),
		};
		this.logger.info('SYNC', 'Manual cross-device diagnostic', payload);
		await this.writeSyncDiagnostic('manual-diagnostic', payload);
		new Notice(
			`RCP-E diagnostic logged. See rcp-enhanced-logs/ and cursor-state/.diag-${this.settings.deviceId}.json`
		);
		await this.logger.flushToFile();
	}

	async seedRemoteStoreRevisionSnapshot(): Promise<void> {
		const ownId = this.settings.deviceId ?? 'unknown';
		for (const filePath of await this.listDeviceStoreFiles()) {
			const deviceId = getDeviceIdFromStorePath(filePath);
			if (!deviceId || deviceId === ownId) continue;
			try {
				if (!(await this.app.vault.adapter.exists(filePath))) continue;
				const raw = await this.app.vault.adapter.read(filePath);
				const parsed = parseDeviceStoreJson(raw);
				if (parsed) {
					this.remoteStoreRevisionSnapshot.set(deviceId, parsed.storeRevision);
				}
			} catch {
				// ignore unreadable remote store on startup
			}
		}
	}

	invalidateRemoteDeviceStoreCache(deviceId?: string): void {
		if (deviceId) {
			this.remoteDeviceStoresCache.delete(deviceId);
			return;
		}
		this.remoteDeviceStoresCache.clear();
	}

	async tryApplyMergedStateForNote(
		notePath: string,
		trigger: string,
		triggerFile?: string
	): Promise<boolean> {
		if (this.loadingFile || this.reloadingState) {
			return false;
		}
		if (this.app.workspace.getActiveFile()?.path !== notePath) {
			return false;
		}

		const merged = await this.readMergedNoteState(notePath);
		if (!merged || !isValidState(merged)) {
			this.logger.debug('SYNC', 'No valid merged state to apply', { notePath, trigger, triggerFile });
			return false;
		}

		if (!shouldApplyMergedState(merged, this.lastEphemeralState)) {
			const reason = explainApplyRejection(merged, this.lastEphemeralState);
			const editorNow = summarizeState(this.getEphemeralState());
			this.logger.info('SYNC', 'Merged state not applied', {
				notePath,
				trigger,
				triggerFile,
				reason,
				winnerDeviceId: this.lastMergeAnalysis?.winnerDeviceId,
				incoming: summarizeState(merged),
				applied: summarizeState(this.lastEphemeralState),
				editorNow,
			});
			void this.writeSyncDiagnostic('apply-rejected', {
				notePath,
				trigger,
				reason,
				winnerDeviceId: this.lastMergeAnalysis?.winnerDeviceId,
				incoming: summarizeState(merged),
				applied: summarizeState(this.lastEphemeralState),
				editorNow,
			});
			return false;
		}

		const winnerDeviceId = this.lastMergeAnalysis?.winnerDeviceId ?? null;
		this.logger.info('SYNC', 'Applying newer merged state', {
			notePath,
			trigger,
			triggerFile,
			winnerDeviceId,
			ownDeviceId: this.settings.deviceId,
			crossDevice: winnerDeviceId != null && winnerDeviceId !== this.settings.deviceId,
			incomingTime: merged.lastModified ?? 0,
			localTime: this.lastEphemeralState?.lastModified ?? 0,
			editorBefore: summarizeState(this.getEphemeralState()),
			state: summarizeState(merged),
		});
		await this.applyScrollState(notePath, merged, trigger, winnerDeviceId);
		void this.writeSyncDiagnostic('apply-accepted', {
			notePath,
			trigger,
			winnerDeviceId,
			state: summarizeState(merged),
			editorAfter: summarizeState(this.getEphemeralState()),
		});
		return true;
	}

	async pollRemoteStateForActiveNote(trigger: string): Promise<void> {
		const notePath = this.lastLoadedFileName;
		if (!notePath || this.loadingFile || this.reloadingState) {
			return;
		}
		if (Date.now() < this.restoreGraceUntil) {
			return;
		}

		const ownId = this.settings.deviceId ?? 'unknown';
		let remoteChanged = false;
		for (const filePath of await this.listDeviceStoreFiles()) {
			const deviceId = getDeviceIdFromStorePath(filePath);
			if (!deviceId || deviceId === ownId) continue;

			try {
				if (!(await this.app.vault.adapter.exists(filePath))) continue;
				const raw = await this.app.vault.adapter.read(filePath);
				const parsed = parseDeviceStoreJson(raw);
				if (!parsed) continue;

				const prev = this.remoteStoreRevisionSnapshot.get(deviceId);
				this.remoteStoreRevisionSnapshot.set(deviceId, parsed.storeRevision);
				this.remoteDeviceStoresCache.set(deviceId, parsed);

				if (prev != null && parsed.storeRevision !== prev) {
					remoteChanged = true;
					const noteHash = getFileHash(notePath);
					const remoteNote = parsed.notes[noteHash];
					this.logger.info('SYNC', 'Remote device store revision changed (LiveSync/poll)', {
						trigger,
						deviceId,
						filePath,
						prevRevision: prev,
						newRevision: parsed.storeRevision,
						activeNote: notePath,
						activeNoteHash: noteHash,
						remoteNoteForActive: remoteNote
							? summarizeState({ ...remoteNote, filePath: notePath })
							: null,
					});
				}
			} catch (e) {
				this.logger.warn('SYNC', 'Failed to poll remote device store', {
					trigger,
					filePath,
					err: e instanceof Error ? e.message : String(e),
				});
			}
		}

		if (!remoteChanged) {
			this.logger.debug('SYNC', 'Remote poll — no device store revision change', {
				trigger,
				notePath,
			});
		}

		await this.tryApplyMergedStateForNote(notePath, trigger);
	}

	async handleExternalStateChange(stateFilePath: string) {
		if (this.reloadingState) {
			this.logger.debug('SYNC', 'External change skipped — already reloading', { stateFilePath });
			return;
		}
		this.reloadingState = true;

		try {
			const fileName = stateFilePath.split('/').pop() ?? '';
			const remoteDeviceId = getDeviceIdFromStorePath(stateFilePath);
			const isRemoteDeviceStore =
				isDeviceStoreFileName(fileName) &&
				remoteDeviceId != null &&
				remoteDeviceId !== (this.settings.deviceId ?? 'unknown');

			if (isRemoteDeviceStore) {
				this.invalidateRemoteDeviceStoreCache(remoteDeviceId);
				await this.readStateFile(stateFilePath);
				const activeFile = this.app.workspace.getActiveFile()?.path;
				if (!activeFile || this.loadingFile) {
					this.logger.debug('SYNC', 'Remote device store changed — no active note', {
						stateFilePath,
						remoteDeviceId,
					});
					return;
				}
				await this.tryApplyMergedStateForNote(
					activeFile,
					'external-device-store',
					stateFilePath
				);
				return;
			}

			const changed = await this.readStateFile(stateFilePath);
			const notePath = changed?.filePath ?? this.app.workspace.getActiveFile()?.path;
			if (!notePath) {
				this.logger.warn('SYNC', 'External state change — could not resolve note path', {
					stateFilePath,
				});
				return;
			}

			await this.tryApplyMergedStateForNote(notePath, 'external-sync', stateFilePath);
		} catch (e) {
			this.logger.error('SYNC', 'Failed to handle external state change', e, { stateFilePath });
		} finally {
			this.reloadingState = false;
		}
	}

	async renameFile(file: TAbstractFile, oldPath: string) {
		this.logger.info('EVENT', 'Renaming state', { from: oldPath, to: file.path });
		const oldHash = getFileHash(oldPath);
		const store = await this.loadOwnDeviceStore();
		const entry = store.notes[oldHash];
		if (entry) {
			await this.writeNoteState(file.path, { ...entry, filePath: file.path });
			const fresh = await this.loadOwnDeviceStore();
			const { [oldHash]: _removed, ...rest } = fresh.notes;
			await this.persistOwnDeviceStore({
				...fresh,
				notes: rest,
				storeRevision: fresh.storeRevision + 1,
			});
		}

		if (this.lastLoadedFileName === oldPath) {
			this.lastLoadedFileName = file.path;
		}
	}

	async deleteFile(file: TAbstractFile) {
		if (
			isForbiddenSharedLogPath(file.path) ||
			file.path.replace(/\\/g, '/').startsWith(LOG_DIR + '/') ||
			this.isStateFilePath(file.path)
		) {
			this.logger.debug('EVENT', 'Ignoring delete of plugin internal file', { path: file.path });
			return;
		}
		this.logger.info('EVENT', 'Deleting state for removed note', { path: file.path });
		await this.deleteNoteState(file.path);
		if (this.lastLoadedFileName === file.path) {
			this.lastLoadedFileName = '';
			this.lastEphemeralState = {};
		}
	}

	setupDOMEventListeners() {
		this.registerDomEvent(document, 'mouseup', () => this.checkEphemeralStateChanged());

		this.registerDomEvent(document, 'keyup', (evt) => {
			if ([
				'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight',
				'Home', 'End', 'PageUp', 'PageDown',
			].includes(evt.key)) {
				this.checkEphemeralStateChanged();
			}
		});

		this.app.workspace.onLayoutReady(() => this.attachScrollListeners());
	}

	attachScrollListeners() {
		if (this.scrollListenersAttached) return;

		const attach = (el: Element | null, name: string) => {
			if (!el) {
				this.logger.debug('EVENT', 'Scroll listener target not found', { target: name });
				return;
			}
			this.registerDomEvent(el as HTMLElement, 'scroll', () => this.checkEphemeralStateChanged(), {
				passive: true,
				capture: true,
			});
			this.logger.debug('EVENT', 'Scroll listener attached', { target: name });
		};

		attach(document.querySelector('.workspace'), 'workspace');
		attach(document.querySelector('.workspace-leaf-content'), 'workspace-leaf-content');
		attach(document.querySelector('.cm-editor'), 'cm-editor');
		this.registerDomEvent(document.body, 'scroll', () => this.checkEphemeralStateChanged(), {
			passive: true,
			capture: true,
		});

		this.scrollListenersAttached = true;
		this.logger.info('EVENT', 'Scroll listeners attached');
	}

	checkEphemeralStateChanged() {
		requestAnimationFrame(() => this.performStateCheck());
	}

	performStateCheck() {
		const fileName = this.app.workspace.getActiveFile()?.path;
		if (!fileName || !this.lastLoadedFileName || fileName !== this.lastLoadedFileName || this.loadingFile) {
			return;
		}

		if (Date.now() < this.restoreGraceUntil) {
			this.logger.debug('STATE', 'performStateCheck skipped — restore grace period', {
				fileName,
				graceMsRemaining: this.restoreGraceUntil - Date.now(),
			});
			return;
		}

		if (!this.hasActiveMarkdownViewFor(fileName)) {
			return;
		}

		const st = this.getEphemeralState();
		if (!isValidState(st)) {
			const view = this.app.workspace.getActiveViewOfType(MarkdownView);
			this.logger.debug('STATE', 'performStateCheck — invalid/empty state captured', {
				fileName,
				hasView: !!view,
				scrollFromMode: view?.currentMode?.getScroll?.(),
				hasEditor: !!this.getEditor(),
			});
			return;
		}

		// Editor not ready after open — scroll 0 at origin is not a real user position.
		if (
			(st.scroll ?? 0) < 5 &&
			(!st.cursor || (st.cursor.from.line === 0 && st.cursor.from.ch === 0)) &&
			!isValidState(this.lastEphemeralState)
		) {
			this.logger.debug('STATE', 'performStateCheck — skipping default scroll-0 before editor is ready', {
				fileName,
			});
			return;
		}

		const enriched = this.enrichStateWithAnchor(st, fileName);
		if (!isEphemeralStatesEquals(enriched, this.lastEphemeralState)) {
			this.logger.debug('STATE', 'State changed — queueing save', {
				fileName,
				previous: summarizeState(this.lastEphemeralState),
				current: summarizeState(enriched),
			});
			this.lastEphemeralState = { ...enriched, filePath: fileName, lastModified: Date.now() };
			this.queueSave(fileName, this.lastEphemeralState);
		}
	}

	async forceRestoreCurrentNote(): Promise<void> {
		const file = this.app.workspace.getActiveFile();
		if (!file || !this.shouldTrackFile(file)) {
			new Notice('Open a markdown note first.');
			return;
		}

		const st = await this.readMergedNoteState(file.path);
		if (!st || !isValidState(st)) {
			new Notice('No saved scroll position found for this note.');
			this.logger.info('RESTORE', 'Force restore — no merged state', { notePath: file.path });
			return;
		}

		const files = await this.listStateFilesForNote(file.path);
		this.logger.info('RESTORE', 'Force restore from merged state', {
			notePath: file.path,
			sourceFileCount: files.length,
			state: summarizeState(st),
		});

		this.loadingFile = false;
		this.lastLoadedFileName = file.path;
		await this.applyScrollState(
			file.path,
			st,
			'force-restore-command',
			this.lastMergeAnalysis?.winnerDeviceId ?? null
		);
		new Notice(`Restored scroll ${st.scroll?.toFixed(1)}% (from ${files.length} state file(s)).`);
	}

	async restoreCurrentNote() {
		const file = this.app.workspace.getActiveFile();
		if (file && this.shouldTrackFile(file)) {
			this.logger.debug('RESTORE', 'restoreCurrentNote on startup', { path: file.path });
			await this.onFileOpen(file);
		}
	}

	scheduleSyncRetryRestore(notePath: string): void {
		for (const timer of this.syncRetryRestoreTimers) {
			window.clearTimeout(timer);
		}
		this.syncRetryRestoreTimers = [];

		const delays = this.settings.aggressiveCrossDeviceSync
			? SYNC_RETRY_DELAYS_AGGRESSIVE
			: SYNC_RETRY_DELAYS_NORMAL;

		for (const delayMs of delays) {
			const timer = window.setTimeout(() => {
				void this.trySyncRetryRestore(notePath);
			}, delayMs);
			this.syncRetryRestoreTimers.push(timer);
		}
	}

	getEffectiveSaveDebounceMs(): number {
		if (this.settings.aggressiveCrossDeviceSync) {
			return Math.min(this.settings.saveDebounceMs, AGGRESSIVE_SAVE_DEBOUNCE_MS);
		}
		return this.settings.saveDebounceMs;
	}

	getSyncRetryRestoreMs(): number {
		return this.settings.aggressiveCrossDeviceSync
			? AGGRESSIVE_SYNC_RETRY_RESTORE_MS
			: SYNC_RETRY_RESTORE_MS;
	}

	createDebouncedSave(): Debouncer<[string, EphemeralState], void> {
		return debounce(
			(filePath: string, state: EphemeralState) => {
				this.logger.debug('SAVE', 'Debounced save fired', {
					notePath: filePath,
					state: summarizeState(state),
				});
				void this.writeNoteState(filePath, state);
			},
			this.getEffectiveSaveDebounceMs(),
			false
		);
	}

	applySaveDebounce(): void {
		if (this.debouncedSave) {
			this.debouncedSave.cancel();
		}
		this.debouncedSave = this.createDebouncedSave();
	}

	applyPeriodicFlush(): void {
		this.stopPeriodicFlush();
		if (!this.settings.aggressiveCrossDeviceSync && !this.settings.reloadOnExternalChange) {
			return;
		}

		const intervalMs = this.settings.aggressiveCrossDeviceSync
			? AGGRESSIVE_PERIODIC_FLUSH_MS
			: 3000;

		this.periodicFlushInterval = window.setInterval(() => {
			if (this.loadingFile || !this.lastLoadedFileName) return;
			void this.pollRemoteStateForActiveNote('periodic-poll');
			if (this.settings.aggressiveCrossDeviceSync) {
				this.logger.debug('FLUSH', 'Periodic flush (aggressive sync)', {
					notePath: this.lastLoadedFileName,
				});
				void this.flushCurrentNote(true);
			}
		}, intervalMs);
	}

	stopPeriodicFlush(): void {
		if (this.periodicFlushInterval != null) {
			window.clearInterval(this.periodicFlushInterval);
			this.periodicFlushInterval = null;
		}
	}

	async trySyncRetryRestore(notePath: string): Promise<void> {
		if (this.lastLoadedFileName !== notePath || this.loadingFile) {
			this.logger.debug('SYNC', 'Delayed re-restore skipped — note no longer active', { notePath });
			return;
		}

		const st = await this.readNoteState(notePath);
		if (!st || !isValidState(st)) {
			this.logger.info('SYNC', 'Delayed re-restore — still no valid merged state on disk', {
				notePath,
				stateFilePath: this.getStateFilePathForNote(notePath),
			});
			return;
		}

		if (!shouldApplyMergedState(st, this.lastEphemeralState)) {
			this.logger.debug('SYNC', 'Delayed re-restore — merged state not better than applied', {
				notePath,
				disk: summarizeState(st),
				applied: summarizeState(this.lastEphemeralState),
			});
			return;
		}

		this.logger.info('SYNC', 'Delayed re-restore — applying better merged state', {
			notePath,
			state: summarizeState(st),
		});
		await this.applyScrollState(
			notePath,
			st,
			'delayed-re-restore',
			this.lastMergeAnalysis?.winnerDeviceId ?? null
		);
	}

	async applyScrollState(
		notePath: string,
		st: EphemeralState,
		reason: string,
		sourceDeviceId: string | null = null
	): Promise<void> {
		await this.delay(this.settings.delayAfterFileOpening);
		if (this.app.workspace.containerEl.querySelector('.is-flashing')) {
			this.logger.info('RESTORE', 'Apply skipped — link flash active', { notePath, reason });
			return;
		}

		const ownId = this.settings.deviceId ?? 'unknown';
		const crossDevice = sourceDeviceId != null && sourceDeviceId !== ownId;
		const editorBefore = summarizeState(this.getEphemeralState());

		await this.delay(10);
		this.logger.info('RESTORE', 'Applying saved state to editor', {
			notePath,
			reason,
			sourceDeviceId,
			crossDevice,
			platform: this.getDevicePlatformLabel(),
			state: summarizeState(st),
			editorBefore,
		});
		this.setEphemeralState(st, { crossDevice, sourceDeviceId });
		this.lastEphemeralState = st;
		this.restoreGraceUntil = Date.now() + RESTORE_GRACE_MS;
		if ((st.scroll ?? 0) > 20) {
			this.clearCrossDeviceSyncWatch(notePath);
		}
		const editorAfter = summarizeState(this.getEphemeralState());
		this.logger.info('RESTORE', 'After apply — editor state', {
			notePath,
			reason,
			crossDevice,
			target: summarizeState(st),
			editorAfter,
			scrollDelta: (editorAfter.scroll as number ?? 0) - (st.scroll ?? 0),
		});
		await this.verifyScrollRestore(notePath, st, crossDevice);
	}

	async verifyScrollRestore(
		notePath: string,
		target: EphemeralState,
		crossDevice = false
	): Promise<void> {
		if (target.scroll == null || target.scroll < 20) {
			return;
		}

		const tolerance = crossDevice ? 80 : 15;

		for (let attempt = 0; attempt < 4; attempt++) {
			await this.delay(attempt === 0 ? 80 : 150 * attempt);
			if (this.lastLoadedFileName !== notePath) {
				return;
			}

			const currentScroll = this.getEphemeralState().scroll ?? 0;
			const targetScroll = target.scroll ?? 0;
			if (Math.abs(currentScroll - targetScroll) <= tolerance) {
				if (attempt > 0 || crossDevice) {
					this.logger.info('RESTORE', 'Scroll verify OK', {
						notePath,
						attempt,
						crossDevice,
						tolerance,
						targetScroll,
						currentScroll,
						targetLine: target.cursor?.from.line,
						currentLine: this.getEphemeralState().cursor?.from.line,
					});
				}
				return;
			}

			if (crossDevice && target.cursor) {
				const currentLine = this.getEphemeralState().cursor?.from.line;
				if (currentLine != null && Math.abs(currentLine - target.cursor.from.line) <= 2) {
					this.logger.info('RESTORE', 'Cross-device line verify OK (scroll pixels differ by platform)', {
						notePath,
						targetLine: target.cursor.from.line,
						currentLine,
						targetScroll,
						currentScroll,
					});
					return;
				}
			}

			// User scrolled shallower than restore target — never yank them back down.
			if (currentScroll < targetScroll - tolerance) {
				this.logger.info('RESTORE', 'Scroll verify skipped — editor is above restore target', {
					notePath,
					crossDevice,
					targetScroll,
					currentScroll,
					targetLine: target.cursor?.from.line,
				});
				return;
			}

			this.logger.warn('RESTORE', 'Scroll verify failed — reapplying scroll', {
				notePath,
				crossDevice,
				attempt: attempt + 1,
				targetScroll,
				currentScroll,
			});
			this.setEphemeralState(target, { crossDevice, sourceDeviceId: null });
		}
	}

	async restoreNoteState(notePath: string) {
		for (let attempt = 1; attempt <= 5; attempt++) {
			try {
				this.logger.debug('RESTORE', 'restoreNoteState attempt', { notePath, attempt });
				const st = await this.readNoteState(notePath);

				if (st && isValidState(st)) {
					await this.applyScrollState(notePath, st, `restore-attempt-${attempt}`);
					return;
				}

				this.lastEphemeralState = st ?? {};
				this.logger.info('RESTORE', 'No valid saved state to restore', {
					notePath,
					attempt,
					stateFilePath: this.getStateFilePathForNote(notePath),
				});
				return;
			} catch (e) {
				this.logger.warn('RESTORE', 'restoreNoteState attempt failed', {
					notePath,
					attempt,
					error: e instanceof Error ? e.message : String(e),
				});
				if (attempt === 5) {
					this.logger.error('RESTORE', 'restoreNoteState failed after all retries', e, { notePath });
					return;
				}
				await this.delay(10 * Math.pow(2, attempt - 1));
			}
		}
	}

	async pruneStates() {
		const { pruneOrphans, maxAgeDays, maxCount } = this.settings;
		if (!pruneOrphans && maxAgeDays <= 0 && maxCount <= 0) return;

		await this.ensureStateDir();
		const adapter = this.getStorageAdapter();
		const files = await adapter.listFiles(this.settings.stateDir);
		let totalRemoved = 0;

		for (const filePath of files) {
			const name = filePath.split('/').pop() ?? '';
			if (!isDeviceStoreFileName(name)) continue;

			const raw = await adapter.read(filePath);
			const store = parseDeviceStoreJson(raw);
			if (!store) continue;

			const { store: pruned, removed } = pruneDeviceStore(store, {
				maxAgeDays,
				maxCount,
				noteExists: (fp) =>
					!pruneOrphans || !!this.app.vault.getAbstractFileByPath(fp),
			});

			if (removed > 0) {
				await adapter.write(filePath, JSON.stringify(pruned));
				totalRemoved += removed;
				if (store.deviceId === this.settings.deviceId) {
					this.ownDeviceStoreCache = pruned;
				} else {
					this.remoteDeviceStoresCache.set(store.deviceId, pruned);
				}
			}
		}

		if (totalRemoved > 0) {
			this.logger.info('SETTINGS', 'Pruned note entries from device stores', { totalRemoved });
		}
	}

	async countStoredStates(): Promise<number> {
		const store = await this.loadOwnDeviceStore();
		return Object.keys(store.notes).length;
	}

	getEphemeralState(): EphemeralState {
		const state: EphemeralState = {};
		const view = this.app.workspace.getActiveViewOfType(MarkdownView);
		if (!view) return state;

		let scroll = view.currentMode?.getScroll();
		if (scroll == null || isNaN(scroll)) {
			const editor = this.getEditor();
			if (editor) {
				const scrollInfo = editor.getScrollInfo();
				if (scrollInfo?.top != null && !isNaN(scrollInfo.top)) {
					scroll = scrollInfo.top;
				}
			}
		}
		if (scroll != null && !isNaN(scroll)) {
			state.scroll = Number(scroll.toFixed(4));
		}

		const editor = this.getEditor();
		if (editor) {
			const from = editor.getCursor('anchor');
			const to = editor.getCursor('head');
			if (from && to) {
				state.cursor = {
					from: { ch: from.ch, line: from.line },
					to: { ch: to.ch, line: to.line },
				};
			}
		}

		return state;
	}

	enrichStateWithAnchor(st: EphemeralState, fileName: string): EphemeralState {
		const editor = this.getEditor();
		if (!editor || st.cursor == null) return st;
		try {
			const lines = editor.getValue().split('\n');
			const anchorLine = findNearestHeadingLine(lines, st.cursor.from.line);
			return { ...st, anchorLine };
		} catch {
			return st;
		}
	}

	setEphemeralState(
		state: EphemeralState,
		options?: { crossDevice?: boolean; sourceDeviceId?: string | null }
	) {
		const view = this.app.workspace.getActiveViewOfType(MarkdownView);
		const editor = this.getEditor();
		const anchorLine = getAnchorLineFromState(state);
		const crossDevice = options?.crossDevice ?? false;

		this.logger.debug('RESTORE', 'setEphemeralState called', {
			hasView: !!view,
			hasCursor: !!state.cursor,
			scroll: state.scroll,
			anchorLine,
			crossDevice,
			sourceDeviceId: options?.sourceDeviceId,
			platform: this.getDevicePlatformLabel(),
		});

		if (state.cursor && editor) {
			editor.setSelection(state.cursor.from, state.cursor.to);
		} else if (state.cursor) {
			this.logger.warn('RESTORE', 'setEphemeralState — no editor for cursor', {
				cursor: state.cursor,
			});
		}

		// Cross-device: line/heading anchor is reliable; raw scroll pixels differ by screen/font.
		const scrollTargetLine =
			state.cursor?.from.line ?? anchorLine;
		if (editor && scrollTargetLine != null) {
			try {
				const lineCh = { line: scrollTargetLine, ch: state.cursor?.from.ch ?? 0 };
				editor.scrollIntoView({ from: lineCh, to: lineCh }, true);
			} catch {
				// fall through
			}
		} else if (editor && anchorLine != null) {
			try {
				const lineCh = { line: anchorLine, ch: 0 };
				editor.scrollIntoView({ from: lineCh, to: lineCh }, true);
			} catch {
				// fall through
			}
		}

		if (view && state.scroll != null && !isNaN(state.scroll) && !crossDevice) {
			view.setEphemeralState({ scroll: state.scroll });
			const mode = view.currentMode;
			if (mode && typeof mode.applyScroll === 'function') {
				mode.applyScroll(state.scroll);
			}
			requestAnimationFrame(() => {
				const retryView = this.app.workspace.getActiveViewOfType(MarkdownView);
				if (!retryView || retryView.file?.path !== this.lastLoadedFileName) return;
				const retryMode = retryView.currentMode;
				if (retryMode && typeof retryMode.applyScroll === 'function') {
					retryMode.applyScroll(state.scroll!);
				}
			});
		} else if (crossDevice && state.scroll != null) {
			this.logger.info('RESTORE', 'Cross-device restore — skipped pixel scroll (using line anchor)', {
				remoteScroll: state.scroll,
				line: scrollTargetLine,
				anchorLine,
			});
		} else if (state.scroll != null) {
			this.logger.warn('RESTORE', 'setEphemeralState — scroll not applied', {
				scroll: state.scroll,
				hasView: !!view,
				crossDevice,
			});
		}
	}

	private shouldTrackFile(file: TFile): boolean {
		// Skip Obsidian Bases and other non-note views
		if (file.extension === 'base') return false;
		return true;
	}

	private hasActiveMarkdownViewFor(filePath: string): boolean {
		const view = this.app.workspace.getActiveViewOfType(MarkdownView);
		return !!view && view.file?.path === filePath;
	}

	private getEditor(): Editor | undefined {
		return this.app.workspace.getActiveViewOfType(MarkdownView)?.editor;
	}

	async loadSettings() {
		const loaded = await this.loadData() as Partial<PluginSettings> | null;
		const { deviceId: _legacySyncedDeviceId, ...sharedLoaded } = loaded ?? {};
		const settings: PluginSettings = Object.assign({}, DEFAULT_SETTINGS, sharedLoaded);

		if (settings.saveDebounceMs == null || settings.saveDebounceMs < 100) {
			settings.saveDebounceMs = DEFAULT_SAVE_DEBOUNCE_MS;
		}
		if (settings.reloadOnExternalChange === undefined) {
			settings.reloadOnExternalChange = true;
		}
		if (settings.debugLogging === undefined) {
			settings.debugLogging = true;
		}
		if (settings.logToFile === undefined) {
			settings.logToFile = true;
		}
		if (settings.syncthingIgnoreLegacyLogs === undefined) {
			settings.syncthingIgnoreLegacyLogs = true;
		}
		if (settings.aggressiveCrossDeviceSync === undefined) {
			settings.aggressiveCrossDeviceSync = true;
		}
		const legacyPluginStateDir = this.manifest.dir + '/states';
		if (!settings.stateDir) {
			settings.stateDir = RECOMMENDED_STATE_DIR;
		} else if (settings.stateDir === legacyPluginStateDir) {
			settings.stateDir = RECOMMENDED_STATE_DIR;
		}

		settings.deviceId = await this.loadLocalDeviceId();
		this.settings = settings;

		const switchedToLiveSyncDir =
			settings.stateDir === RECOMMENDED_STATE_DIR &&
			(loaded?.stateDir === legacyPluginStateDir || !loaded?.stateDir);
		if (switchedToLiveSyncDir || _legacySyncedDeviceId) {
			await this.saveSharedSettings(settings);
		}
	}

	async saveSettings() {
		await this.saveSharedSettings(this.settings);
	}

	private async saveSharedSettings(settings: PluginSettings) {
		const { deviceId: _deviceId, ...shared } = settings;
		await this.saveData(shared);
	}

	async delay(ms: number) {
		return new Promise((resolve) => setTimeout(resolve, ms));
	}
}

class SettingTab extends PluginSettingTab {
	plugin: RememberCursorPosition;

	constructor(app: App, plugin: RememberCursorPosition) {
		super(app, plugin);
		this.plugin = plugin;
	}

	display(): void {
		const { containerEl } = this;
		containerEl.empty();

		containerEl.createEl('h2', {
			text: `Remember cursor position — v${this.plugin.manifest.version}`,
		});
		containerEl.createEl('p', {
			text: `${this.plugin.getDeviceLabel()} · device id ${this.plugin.settings.deviceId ?? 'unknown'} · ${this.plugin.getDevicePlatformLabel()}`,
			cls: 'setting-item-description',
		});

		new Setting(containerEl)
			.setName('State storage folder')
			.setDesc(
				'v2: one file per device ({deviceId}.json) with all note positions. ' +
				'Default cursor-state/ at vault root syncs quickly via Self-hosted LiveSync. ' +
				'Add cursor-state/ to Settings → Files & links → Excluded files. ' +
				'Legacy plugin/states/ files migrate here automatically on startup.'
			)
			.addText((text) =>
				text
					.setPlaceholder('cursor-state')
					.setValue(this.plugin.settings.stateDir)
					.onChange(async (value) => {
						this.plugin.settings.stateDir = value;
						await this.plugin.saveSettings();
					})
			);

		new Setting(containerEl)
			.setName('Delay after opening a new note')
			.setDesc(
				"Skips restore when you open a note via a header link like [[note#heading]]. Increase if restore overrides link navigation. Set to 0 if you don't use section links."
			)
			.addSlider((text) =>
				text
					.setLimits(0, 300, 10)
					.setDynamicTooltip()
					.setValue(this.plugin.settings.delayAfterFileOpening)
					.onChange(async (value) => {
						this.plugin.settings.delayAfterFileOpening = value;
						await this.plugin.saveSettings();
					})
			);

		new Setting(containerEl)
			.setName('Save delay after last change')
			.setDesc(
				'How long to wait after you stop scrolling or moving the cursor before writing to disk. ' +
				'Lower values sync to other devices faster; the app also saves immediately when you switch notes or background Obsidian.'
			)
			.addSlider((text) =>
				text
					.setLimits(100, 2000, 50)
					.setDynamicTooltip()
					.setValue(this.plugin.settings.saveDebounceMs)
					.onChange(async (value) => {
						this.plugin.settings.saveDebounceMs = value;
						await this.plugin.saveSettings();
						this.plugin.applySaveDebounce();
					})
			);

		new Setting(containerEl)
			.setName('Fast cross-device sync')
			.setDesc(
				'Fastest practical plugin settings: 150 ms save delay (or lower if your slider is below that), ' +
				'flush to disk every 2 seconds while a note is open, and quicker re-restore after a synced update. ' +
				'After the file is written, Syncthing still needs your network — typically about 1–10 seconds on Wi‑Fi, ' +
				'often under 2 seconds on the same home LAN. Nothing can sync faster than that path.'
			)
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.aggressiveCrossDeviceSync)
					.onChange(async (value) => {
						this.plugin.settings.aggressiveCrossDeviceSync = value;
						await this.plugin.saveSettings();
						this.plugin.applySaveDebounce();
						this.plugin.applyPeriodicFlush();
					})
			);

		new Setting(containerEl)
			.setName('Reload positions when a state file changes')
			.setDesc(
				'When another device syncs an updated state file, apply it if you have the same note open. ' +
				'Keep this enabled for multi-device use.'
			)
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.reloadOnExternalChange)
					.onChange(async (value) => {
						this.plugin.settings.reloadOnExternalChange = value;
						await this.plugin.saveSettings();
					})
			);

		containerEl.createEl('h3', { text: 'Debug logging' });
		containerEl.createEl('p', {
			text:
				'Logs: rcp-enhanced-logs/{DeviceName}-{deviceId}.log (per device). ' +
				'Sync diagnostics (sync via LiveSync): cursor-state/.diag-{deviceId}.json. ' +
				'Command palette: "Log cross-device sync diagnostic (current note)".',
			cls: 'setting-item-description',
		});

		new Setting(containerEl)
			.setName('Device name')
			.setDesc(
				'Label for this device in log filenames and log lines. ' +
				`Auto-detected: "${this.plugin.getDefaultDeviceName()}". ` +
				'Set a custom name like "Work PC" or "Personal Phone" so synced logs are easy to tell apart on desktop.'
			)
			.addText((text) =>
				text
					.setPlaceholder(this.plugin.getDefaultDeviceName())
					.setValue(this.plugin.settings.deviceName ?? '')
					.onChange(async (value) => {
						this.plugin.settings.deviceName = value.trim();
						await this.plugin.saveSettings();
						this.plugin.initLogger();
						this.plugin.logger.info('SETTINGS', 'deviceName changed', {
							deviceName: this.plugin.getDeviceLabel(),
							logFile: this.plugin.getLogFilePath(),
						});
					})
			);

		new Setting(containerEl)
			.setName('Verbose debug logging')
			.setDesc(
				'Log plugin activity to the developer console (Ctrl+Shift+I). ' +
				'Keep enabled while troubleshooting; disable when everything works.'
			)
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.debugLogging)
					.onChange(async (value) => {
						this.plugin.settings.debugLogging = value;
						await this.plugin.saveSettings();
						this.plugin.logger.info('SETTINGS', 'debugLogging changed', { value });
					})
			);

		new Setting(containerEl)
			.setName('Write debug log to file')
			.setDesc(
				`Each device writes its own named file in ${LOG_DIR}/ (e.g. Windows-Desktop-abc12345.log, Android-Phone-xyz78901.log). ` +
				'These files sync with your vault — after sync, open the folder on desktop to see logs from every device.'
			)
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.logToFile)
					.onChange(async (value) => {
						this.plugin.settings.logToFile = value;
						await this.plugin.saveSettings();
					})
			);

		new Setting(containerEl)
			.setName('This device log file')
			.setDesc(
				`Device: ${this.plugin.getDeviceLabel()} · File: ${this.plugin.getLogFilePath()}`
			)
			.addButton((btn) =>
				btn.setButtonText('Open this device log').onClick(() => {
					void this.plugin.openDebugLog();
				})
			);

		new Setting(containerEl)
			.setName('All device logs')
			.setDesc(
				`Lists every log file synced into ${LOG_DIR}/. ` +
				'Use "Build combined debug log" to merge all devices into one timeline file on desktop.'
			)
			.addButton((btn) =>
				btn.setButtonText('List all logs').onClick(() => {
					void this.plugin.listDeviceDebugLogs();
				})
			)
			.addButton((btn) =>
				btn
					.setButtonText('Build combined log')
					.setTooltip('Merge all device logs into one file sorted by time')
					.onClick(() => {
						void this.plugin.buildCombinedDebugLog();
					})
			);

		new Setting(containerEl)
			.setName('Syncthing: ignore legacy shared logs')
			.setDesc(
				'Adds rules to .stignore so rcp-enhanced-debug.log and conflict copies are never synced. ' +
				'This permanently stops Syncthing conflict storms from old shared log files. Keep enabled.'
			)
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.syncthingIgnoreLegacyLogs)
					.onChange(async (value) => {
						this.plugin.settings.syncthingIgnoreLegacyLogs = value;
						await this.plugin.saveSettings();
						if (value) {
							await this.plugin.ensureSyncthingIgnoreRules();
						}
					})
			);

		new Setting(containerEl)
			.setName('Clean up old shared log files')
			.setDesc(
				'Removes rcp-enhanced-debug.log, sync-conflict copies, and old plugin-folder debug.log files. ' +
				'Those shared files caused Syncthing conflicts when every device wrote to the same path.'
			)
			.addButton((btn) =>
				btn.setButtonText('Clean up now').onClick(() => {
					void this.plugin.cleanupLegacyPluginDebugLogs(true);
				})
			);

		new Setting(containerEl)
			.setName('Clear this device log')
			.setDesc('Remove entries only from this device log file (other devices keep their logs)')
			.addButton((btn) =>
				btn.setButtonText('Clear log').onClick(async () => {
					await this.plugin.clearDebugLog();
					new Notice('RCP-E debug log cleared');
				})
			);

		const { pruneOrphans, maxAgeDays, maxCount } = this.plugin.settings;
		const pruningEnabled = pruneOrphans || maxAgeDays > 0 || maxCount > 0;

		void this.plugin.countStoredStates().then((entryCount) => {
			containerEl.createEl('h3', { text: 'Pruning' });

			new Setting(containerEl)
				.setName('Remove entries for deleted or missing files')
				.setDesc(
					'Remove saved positions for files that no longer exist in the vault. ' +
					'Disable if files may be temporarily unavailable (removable drives, junctions).'
				)
				.addToggle((toggle) =>
					toggle
						.setValue(this.plugin.settings.pruneOrphans)
						.onChange(async (value) => {
							this.plugin.settings.pruneOrphans = value;
							await this.plugin.saveSettings();
							this.display();
						})
				);

			new Setting(containerEl)
				.setName('Remove entries older than')
				.setDesc('Remove saved positions for files not visited within the selected period.')
				.addDropdown((drop) =>
					drop
						.addOption('30', '30 days')
						.addOption('60', '60 days')
						.addOption('90', '90 days')
						.addOption('365', '1 year')
						.addOption('0', 'Never')
						.setValue(String(this.plugin.settings.maxAgeDays))
						.onChange(async (value) => {
							this.plugin.settings.maxAgeDays = Number(value);
							await this.plugin.saveSettings();
							this.display();
						})
				);

			new Setting(containerEl)
				.setName('Maximum number of entries to keep')
				.setDesc('If saved positions exceed this limit, the least recently visited are removed.')
				.addDropdown((drop) =>
					drop
						.addOption('50', '50')
						.addOption('100', '100')
						.addOption('250', '250')
						.addOption('500', '500')
						.addOption('0', 'Never')
						.setValue(String(this.plugin.settings.maxCount))
						.onChange(async (value) => {
							this.plugin.settings.maxCount = Number(value);
							await this.plugin.saveSettings();
							this.display();
						})
				);

			new Setting(containerEl)
				.setName('Apply pruning rules')
				.setDesc(`Currently tracking ${entryCount} ${entryCount === 1 ? 'entry' : 'entries'}.`)
				.addButton((btn) => {
					btn.setButtonText('Prune now')
						.setDisabled(!pruningEnabled);
					if (pruningEnabled) btn.setCta();
					btn.onClick(async () => {
						await this.plugin.pruneStates();
						this.display();
					});
				});
		});
	}
}
