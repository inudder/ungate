import { sleep, type ApiStatus as ServerStatus, type LogEntry } from '@ungate/shared';
import * as vscode from 'vscode';

import { RuntimeStateStore } from './runtime-state';
import { config } from './runtime-state/config';
import { NssmService } from './utils/nssm-service';
import { UngateSettingsReader } from './utils/ungate-settings-reader';

const HEALTH_CHECK_URL = (port: number) => `http://localhost:${port}/health`;
const STARTING_STATE_TIMEOUT_MS = 10000;
const DEFAULT_PORT = 47821;

interface ApiServerCallbacks {
	onLog(level: LogEntry['level'], message: string): void;
	onPortDetected(port: number): void;
	onStatusChange(status: ServerStatus): void;
	isLeaderWindow(): boolean;
	isExtensionHostActive(): boolean;
	getWindowId(): string;
}

/**
 * Attach-only API server controller.
 *
 * The API process is managed by an NSSM Windows service (`ungate-api` by default).
 * This class never spawns the process itself — it attaches to the running service
 * via health-check polling and controls lifecycle through `nssm restart`.
 *
 * This mirrors the pattern used by `TunnelManager` for the frpc NSSM service.
 */
export class ApiServer {
	private healthCheckTimer: NodeJS.Timeout | null = null;
	private lastStatus: ServerStatus | null = null;
	private port: number | null = null;
	private startPromise: Promise<void> | null = null;
	private restartInProgress = false;
	private settingsReader: UngateSettingsReader | null = null;
	private consecutiveFailures = 0;
	private healthCheckInFlight = false;

	constructor(
		private readonly context: vscode.ExtensionContext,
		private readonly callbacks: ApiServerCallbacks
	) {}

	async start(): Promise<void> {
		if (this.isAutoStartBlocked()) {
			return;
		}

		if (this.port !== null) {
			return;
		}

		if (this.startPromise) {
			return this.startPromise;
		}

		this.startPromise = this.doStart();

		try {
			await this.startPromise;
		} finally {
			this.startPromise = null;
		}
	}

	isStartupInProgress(): boolean {
		return this.startPromise !== null;
	}

	async restart(): Promise<void> {
		this.restartInProgress = true;
		this.port = null;
		this.stopHealthCheck();
		await RuntimeStateStore.resetApiForRestart();
		await this.setStatus('stopped');

		try {
			this.callbacks.onLog('info', `[process] restarting NSSM service ${config.apiServer.nssmServiceName}`);
			await NssmService.restart(config.apiServer.nssmServiceName);

			const port = await this.resolvePort();
			const healthy = await this.pollUntilHealthy(port);

			if (!healthy) {
				await this.recordApiFailure(`[process] service did not become healthy on port ${port} after restart`);

				return;
			}

			this.port = port;
			this.callbacks.onPortDetected(port);
			await this.setStatus('running');
			this.startHealthCheck();
		} finally {
			this.restartInProgress = false;
		}
	}

	stop(): Promise<void> {
		this.stopHealthCheck();
		this.port = null;

		if (RuntimeStateStore.isApiStartSuppressed()) {
			this.lastStatus = 'error';
			this.callbacks.onStatusChange('error');

			return Promise.resolve();
		}

		// The API process is NSSM-managed and keeps running after the extension
		// detaches. Do NOT overwrite the shared runtime state with 'stopped' —
		// that would falsely report a healthy service as stopped on the next
		// window activation. The real status is re-established by health checks
		// during the next attach (prepareApiForBootstrap / doStart).
		this.lastStatus = 'stopped';
		this.callbacks.onStatusChange('stopped');

		return Promise.resolve();
	}

	getPort(): number | null {
		return this.port;
	}

	syncLeaderHealthMonitor(isLeader: boolean): void {
		if (!isLeader) {
			this.stopHealthCheck();

			return;
		}

		const hasRuntimeTarget = this.port !== null || this.startPromise !== null;

		if (hasRuntimeTarget && !this.healthCheckTimer) {
			this.startHealthCheck();
		}
	}

	private async doStart(): Promise<void> {
		if (this.isAutoStartBlocked()) {
			return;
		}

		const runtimeState = RuntimeStateStore.read();
		const existingPort = runtimeState.api.port;

		// Fast path: attach to a port already recorded in runtime state.
		if (existingPort) {
			const isAlive = await this.checkPortHealth(existingPort);

			if (isAlive) {
				this.port = existingPort;
				this.callbacks.onPortDetected(existingPort);
				await this.setStatus('running');
				this.startHealthCheck();

				return;
			}
		}

		// Another window is already starting — let it finish (coordinates dashboard state).
		if (runtimeState.api.status === 'starting' && runtimeState.api.ownerWindowId !== this.callbacks.getWindowId()) {
			const startingStateAge = Date.now() - runtimeState.api.lastSeenAt;

			if (startingStateAge < STARTING_STATE_TIMEOUT_MS) {
				return;
			}
		}

		await this.setStatus('starting');

		// Resolve the port from app_settings DB (NSSM-managed service port).
		const port = await this.resolvePort();

		// Poll until the NSSM service is healthy on the resolved port.
		const healthy = await this.pollUntilHealthy(port);

		if (!healthy) {
			await this.recordApiFailure(`[process] NSSM service not healthy on port ${port}`);

			return;
		}

		this.port = port;
		this.callbacks.onPortDetected(port);
		await this.setStatus('running');
		this.startHealthCheck();
	}

	private isAutoStartBlocked(): boolean {
		if (this.restartInProgress) {
			return false;
		}

		return RuntimeStateStore.isApiStartSuppressed();
	}

	private async recordApiFailure(message: string): Promise<void> {
		this.consecutiveFailures = 0;
		this.lastStatus = 'error';
		await RuntimeStateStore.suppressApiAutoStart(message);
		this.callbacks.onStatusChange('error');
	}

	/**
	 * Resolves the API port from the `app_settings` SQLite table.
	 * Falls back to `DEFAULT_PORT` (47821) if the DB or row is unavailable.
	 */
	private async resolvePort(): Promise<number> {
		if (!this.settingsReader) {
			this.settingsReader = new UngateSettingsReader((message) => {
				this.callbacks.onLog('info', message);
			});
			await this.settingsReader.init();
		}

		const port = await this.settingsReader.readPort();

		return port ?? DEFAULT_PORT;
	}

	/**
	 * Polls the health endpoint on `port` until it responds OK or the timeout expires.
	 * Used during initial attach and after `nssm restart`.
	 */
	private async pollUntilHealthy(port: number): Promise<boolean> {
		const deadline = Date.now() + config.apiServer.attachPollTimeoutMs;
		const interval = config.apiServer.attachPollIntervalMs;

		while (Date.now() < deadline) {
			const isHealthy = await this.checkPortHealth(port);

			if (isHealthy) {
				return true;
			}

			await sleep(interval);
		}

		return false;
	}

	private startHealthCheck(): void {
		this.stopHealthCheck();

		this.healthCheckTimer = setInterval(() => {
			void this.runHealthCheckCycle().catch(() => {});
		}, config.apiServer.healthCheckIntervalMs);
	}

	private async runHealthCheckCycle(): Promise<void> {
		if (!this.callbacks.isLeaderWindow()) {
			return;
		}

		if (!this.port) {
			return;
		}

		// Skip if a previous health check is still in flight — prevents overlapping
		// cycles (interval < request timeout) from racing on status transitions.
		if (this.healthCheckInFlight) {
			return;
		}

		this.healthCheckInFlight = true;

		try {
			const res = await fetch(HEALTH_CHECK_URL(this.port), {
				signal: AbortSignal.timeout(config.apiServer.healthCheckRequestTimeoutMs)
			});

			if (res.ok) {
				this.consecutiveFailures = 0;
				const wasDown = this.lastStatus !== 'running';

				await this.setStatus('running');

				if (wasDown) {
					this.callbacks.onPortDetected(this.port);
				}
			} else {
				await this.handleHealthCheckFailure(`[process] health check failed with status ${res.status}`);
			}
		} catch {
			await this.handleHealthCheckFailure('[process] health check failed');
		} finally {
			this.healthCheckInFlight = false;
		}
	}

	private async handleHealthCheckFailure(message: string): Promise<void> {
		this.consecutiveFailures++;
		const threshold = config.apiServer.healthCheckFailureThreshold;

		if (this.consecutiveFailures < threshold) {
			// Transient failure — don't flip to 'error' yet to avoid status bar flicker.
			this.callbacks.onLog('info', `${message} (${this.consecutiveFailures}/${threshold})`);

			return;
		}

		await this.recordApiFailure(message);
	}

	private stopHealthCheck(): void {
		if (this.healthCheckTimer) {
			clearInterval(this.healthCheckTimer);
			this.healthCheckTimer = null;
		}
	}

	private async setStatus(status: ServerStatus): Promise<void> {
		const updated = await this.writeRuntimeState(status, null);

		if (updated) {
			this.lastStatus = status;
			this.callbacks.onStatusChange(status);
		}
	}

	private async writeRuntimeState(status: ServerStatus, errorMessage: string | null): Promise<boolean> {
		let updated = false;

		await RuntimeStateStore.mutate((current) => {
			// Only protect a *suppressed* error from being overwritten. A non-suppressed
			// 'error' is a stale/phantom value (e.g. left over from a previous session);
			// a successful health check transitioning to 'running' must be allowed to
			// clear it, otherwise the bar flickers running ↔ error forever.
			if (current.api.status === 'error' && current.api.startSuppressed === true && status !== 'error' && status !== 'stopped') {
				return current;
			}

			const now = Date.now();

			// pid is null — the process is owned by the NSSM service, not the extension.
			current.api.pid = null;
			current.api.port = this.port;
			current.api.status = status;
			current.api.lastSeenAt = now;
			current.api.lastError = errorMessage;

			if (status === 'starting') {
				current.api.ownerWindowId = this.callbacks.getWindowId();
			} else if (status === 'stopped' || status === 'error') {
				current.api.ownerWindowId = null;
			}

			updated = true;

			return current;
		});

		return updated;
	}

	private async checkPortHealth(port: number): Promise<boolean> {
		try {
			const response = await fetch(HEALTH_CHECK_URL(port), {
				signal: AbortSignal.timeout(config.apiServer.portHealthRequestTimeoutMs)
			});

			return response.ok;
		} catch {
			return false;
		}
	}
}
