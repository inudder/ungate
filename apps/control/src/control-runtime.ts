import { randomUUID } from 'node:crypto';

import { EventHub } from './event-hub';
import { LogMonitor } from './log-monitor';
import { NssmClient } from './nssm-client';

import type { ControlConfig } from './config';
import type {
	DashboardLogSource,
	DashboardLogsSnapshot,
	DashboardOperation,
	DashboardServiceAction,
	DashboardServicePhase,
	DashboardServiceStatus,
	DashboardServiceTarget,
	DashboardStatus
} from '@ungate/shared';

interface ServiceResult {
	phase: DashboardServicePhase;
	error: string | null;
}

function sleep(milliseconds: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export class ControlRuntime {
	private readonly operations = new Map<string, DashboardOperation>();
	private readonly operationTails = new Map<DashboardServiceTarget, Promise<void>>();
	private readonly logMonitors: Record<DashboardLogSource, LogMonitor>;
	private statusTimer: NodeJS.Timeout | null = null;
	private statusPollInFlight = false;
	private lastStatusJson = '';

	constructor(
		private readonly config: ControlConfig,
		private readonly nssm: NssmClient,
		private readonly events: EventHub,
		private readonly fetcher: typeof fetch = fetch
	) {
		this.logMonitors = {
			api: new LogMonitor('api', config.apiServiceName, nssm, config.logPollIntervalMs, (source, entry) => {
				events.broadcast({ type: 'log', data: { source, entry } });
			}),
			tunnel: new LogMonitor('tunnel', config.tunnelServiceName, nssm, config.logPollIntervalMs, (source, entry) => {
				events.broadcast({ type: 'log', data: { source, entry } });
			})
		};
	}

	async start(): Promise<void> {
		this.events.start();
		await Promise.all([this.logMonitors.api.start(), this.logMonitors.tunnel.start()]);
		await this.broadcastStatusIfChanged();

		this.statusTimer = setInterval(() => {
			void this.pollStatus();
		}, this.config.statusPollIntervalMs);
		this.statusTimer.unref();
	}

	stop(): void {
		if (this.statusTimer) {
			clearInterval(this.statusTimer);
			this.statusTimer = null;
		}

		this.logMonitors.api.stop();
		this.logMonitors.tunnel.stop();
	}

	async getLogs(source: DashboardLogSource, limit: number): Promise<DashboardLogsSnapshot> {
		return {
			source,
			entries: await this.logMonitors[source].snapshot(limit)
		};
	}

	getOperation(id: string): DashboardOperation | null {
		return this.operations.get(id) ?? null;
	}

	beginOperation(target: DashboardServiceTarget, action: DashboardServiceAction): DashboardOperation {
		if (target === 'api' && action !== 'restart') {
			throw new Error('The API service only supports restart from the dashboard');
		}

		const operation: DashboardOperation = {
			id: randomUUID(),
			target,
			action,
			state: 'queued',
			startedAt: null,
			finishedAt: null,
			error: null
		};
		this.operations.set(operation.id, operation);
		this.events.broadcast({ type: 'operation', data: operation });

		const previous = this.operationTails.get(target) ?? Promise.resolve();
		const task = previous
			.catch(() => undefined)
			.then(async () => {
				await this.executeOperation(operation);
			});
		this.operationTails.set(target, task);
		void task.finally(() => {
			if (this.operationTails.get(target) === task) {
				this.operationTails.delete(target);
			}
		});

		return operation;
	}

	async getStatus(): Promise<DashboardStatus> {
		const [apiService, tunnelService] = await Promise.all([
			this.readService(this.config.apiServiceName),
			this.readService(this.config.tunnelServiceName)
		]);
		const [apiHealthy, tunnelHealthy] = await Promise.all([
			apiService.phase === 'running' ? this.checkHealth(`${this.config.apiUrl}/health`) : Promise.resolve(false),
			tunnelService.phase === 'running' ? this.checkHealth(this.config.tunnelHealthUrl) : Promise.resolve(false)
		]);

		return {
			dashboard: {
				name: 'ungate-dashboard',
				phase: 'running',
				healthy: true,
				error: null,
				port: this.config.port
			},
			api: this.toStatus(this.config.apiServiceName, apiService, apiHealthy, 'API health check failed', {
				port: this.config.apiPort
			}),
			tunnel: this.toStatus(this.config.tunnelServiceName, tunnelService, tunnelHealthy, null, {
				url: this.config.tunnelHealthUrl.replace(/\/health\/?$/, '')
			}),
			checkedAt: Date.now()
		};
	}

	private toStatus<T extends object>(
		name: string,
		service: ServiceResult,
		healthy: boolean,
		unhealthyMessage: string | null,
		extra: T
	): DashboardServiceStatus & T {
		const runningButUnhealthy = service.phase === 'running' && !healthy && unhealthyMessage !== null;

		return {
			name,
			phase: runningButUnhealthy ? 'error' : service.phase,
			healthy,
			error: service.error ?? (runningButUnhealthy ? unhealthyMessage : null),
			...extra
		};
	}

	private async readService(serviceName: string): Promise<ServiceResult> {
		try {
			return { phase: await this.nssm.status(serviceName), error: null };
		} catch (error) {
			return {
				phase: 'error',
				error: error instanceof Error ? error.message : String(error)
			};
		}
	}

	private async checkHealth(url: string): Promise<boolean> {
		try {
			const response = await this.fetcher(url, {
				signal: AbortSignal.timeout(3000)
			});

			return response.ok;
		} catch {
			return false;
		}
	}

	private async executeOperation(operation: DashboardOperation): Promise<void> {
		operation.state = 'running';
		operation.startedAt = Date.now();
		this.events.broadcast({ type: 'operation', data: operation });

		try {
			const serviceName = operation.target === 'api' ? this.config.apiServiceName : this.config.tunnelServiceName;
			await this.nssm.control(serviceName, operation.action);
			await this.waitForOperation(operation);
			operation.state = 'succeeded';
		} catch (error) {
			operation.state = 'failed';
			operation.error = error instanceof Error ? error.message : String(error);
		} finally {
			operation.finishedAt = Date.now();
			this.events.broadcast({ type: 'operation', data: operation });
			await this.broadcastStatusIfChanged();
		}
	}

	private async waitForOperation(operation: DashboardOperation): Promise<void> {
		const deadline = Date.now() + this.config.operationTimeoutMs;

		while (Date.now() < deadline) {
			const status = await this.getStatus();
			const targetStatus = operation.target === 'api' ? status.api : status.tunnel;

			if (this.operationCompleted(operation, targetStatus)) return;

			await sleep(500);
		}

		throw new Error(`${operation.target} ${operation.action} timed out after ${this.config.operationTimeoutMs}ms`);
	}

	private operationCompleted(operation: DashboardOperation, status: DashboardServiceStatus): boolean {
		if (operation.action === 'stop') {
			return status.phase === 'stopped';
		}
		if (status.phase !== 'running') {
			return false;
		}

		return operation.target === 'tunnel' || status.healthy;
	}

	private async pollStatus(): Promise<void> {
		if (this.statusPollInFlight) return;
		this.statusPollInFlight = true;

		try {
			await this.broadcastStatusIfChanged();
		} finally {
			this.statusPollInFlight = false;
		}
	}

	private async broadcastStatusIfChanged(): Promise<void> {
		const status = await this.getStatus();
		const comparable = JSON.stringify({
			dashboard: status.dashboard,
			api: status.api,
			tunnel: status.tunnel
		});

		if (comparable !== this.lastStatusJson) {
			this.lastStatusJson = comparable;
			this.events.broadcast({ type: 'status', data: status });
		}
	}
}
