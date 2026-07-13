import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

import { bin, install, use, Tunnel } from 'cloudflared';

import { RuntimeStateStore } from './runtime-state';
import { config } from './runtime-state/config';

import type { LogEntry, TunnelState } from '@ungate/shared/frontend';

const CLOUDFLARED_BIN_DIR = path.join(os.homedir(), '.ungate', 'bin');

function getCloudflaredBinPath(): string {
	return path.join(CLOUDFLARED_BIN_DIR, process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared');
}

function getCloudflaredLegacyBinPath(): string {
	return path.join(CLOUDFLARED_BIN_DIR, 'cloudflared');
}

export class TunnelManager {
	private tunnel: Tunnel | null = null;
	private state: TunnelState = { status: 'stopped', url: null, error: null };
	private readonly windowId: string;
	private autoStopTimer: NodeJS.Timeout | null = null;
	private tunnelHealthCheckTimer: NodeJS.Timeout | null = null;

	constructor(
		windowId: string,
		private readonly isExtensionHostActive: () => boolean,
		private readonly onStateChange: (state: TunnelState) => void,
		private readonly onLog: (entry: LogEntry) => void
	) {
		this.windowId = windowId;
	}

	getState(): TunnelState {
		return { ...this.state };
	}

	start(port: number): Promise<void> {
		if (this.state.status === 'running') {
			return Promise.resolve();
		}

		if (this.tunnel) {
			this.tunnel.stop();
			this.tunnel = null;
		}

		this.setState({ status: 'starting', url: null, error: null });

		// frpc is NSSM-managed — skip cloudflared binary download
		this.spawnTunnel(port);
		this.scheduleAutoStop();

		return Promise.resolve();
	}

	stop(): void {
		this.stopTunnelHealthCheck();

		if (this.autoStopTimer) {
			clearInterval(this.autoStopTimer);
			this.autoStopTimer = null;
		}

		if (this.tunnel) {
			this.tunnel.stop();
			this.tunnel = null;
		}

		this.setState({ status: 'stopped', url: null, error: null });
	}

	async restart(port: number): Promise<void> {
		this.stop();
		await this.start(port);
	}

	private async ensureBinary(): Promise<void> {
		const devBinExists = fs.existsSync(bin);
		const userBinPath = this.resolveUserBinaryPath();

		if (devBinExists) {
			return;
		}

		if (userBinPath) {
			use(userBinPath);

			return;
		}

		this.setState({ status: 'installing', url: null, error: null });
		this.onLog({ timestamp: Date.now(), level: 'info', message: 'Downloading cloudflared binary...' });

		try {
			fs.mkdirSync(CLOUDFLARED_BIN_DIR, { recursive: true });
			const installPath = getCloudflaredBinPath();
			const installedPath = await install(installPath);

			use(installedPath);
			this.onLog({ timestamp: Date.now(), level: 'info', message: 'cloudflared installed successfully' });
			this.setState({ status: 'starting', url: null, error: null });
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			this.onLog({ timestamp: Date.now(), level: 'error', message: `Failed to install cloudflared: ${message}` });
			this.setState({ status: 'error', url: null, error: `Install failed: ${message}` });
		}
	}

	private resolveUserBinaryPath(): string | null {
		const binPath = getCloudflaredBinPath();

		if (fs.existsSync(binPath)) {
			return binPath;
		}

		const legacyPath = getCloudflaredLegacyBinPath();

		if (process.platform === 'win32' && fs.existsSync(legacyPath)) {
			fs.renameSync(legacyPath, binPath);

			return binPath;
		}

		return null;
	}

	private spawnTunnel(_port: number): void {
		// frpc tunnel — NSSM-managed, URL is fixed
		this.tunnel = { stop: () => {} } as unknown as Tunnel;
		const url = `https://ungate.ahref.cyou`;
		this.onLog({ timestamp: Date.now(), level: 'info', message: `Tunnel URL: ${url}` });
		this.setState({ status: 'starting', url, error: null });
		this.startTunnelHealthCheck(url);
	}

	private startTunnelHealthCheck(url: string): void {
		this.stopTunnelHealthCheck();

		// Initial check immediately
		void this.checkTunnelHealth(url);

		this.tunnelHealthCheckTimer = setInterval(() => {
			void this.checkTunnelHealth(url);
		}, config.tunnelManager.healthCheckIntervalMs);
	}

	private stopTunnelHealthCheck(): void {
		if (this.tunnelHealthCheckTimer) {
			clearInterval(this.tunnelHealthCheckTimer);
			this.tunnelHealthCheckTimer = null;
		}
	}

	private async checkTunnelHealth(url: string): Promise<void> {
		try {
			const response = await fetch(`${url}/health`, {
				signal: AbortSignal.timeout(config.tunnelManager.healthCheckRequestTimeoutMs)
			});

			if (response.ok) {
				if (this.state.status !== 'running') {
					this.setState({ status: 'running', url, error: null });
				}
			} else {
				if (this.state.status !== 'error') {
					this.setState({ status: 'error', url, error: `Tunnel endpoint returned ${response.status}` });
				}
			}
		} catch {
			if (this.state.status !== 'error') {
				this.setState({ status: 'error', url, error: 'Tunnel endpoint unreachable' });
			}
		}
	}

	private setState(next: TunnelState): void {
		this.state = next;
		void this.persistTunnelState(next).catch(() => {});
	}

	private async persistTunnelState(next: TunnelState): Promise<void> {
		await RuntimeStateStore.mutate((current) => {
			current.tunnel.status = next.status;
			current.tunnel.url = next.url;
			current.tunnel.lastSeenAt = Date.now();
			current.tunnel.lastError = next.error;
			current.tunnel.ownerWindowId = this.windowId;

			return current;
		});
		this.onStateChange(next);
	}

	private scheduleAutoStop(): void {
		if (this.autoStopTimer) {
			return;
		}

		this.autoStopTimer = setInterval(() => {
			const runtimeState = RuntimeStateStore.read();
			const hasLiveClientsOnDisk = RuntimeStateStore.hasLiveClients(runtimeState);

			if (!hasLiveClientsOnDisk && !this.isExtensionHostActive()) {
				this.stop();
			}
		}, config.tunnelManager.autoStopCheckIntervalMs);
	}
}
