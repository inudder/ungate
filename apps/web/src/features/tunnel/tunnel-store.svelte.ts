import { dashboardClient } from '$shared/dashboard-client';

import type { DashboardServiceAction, DashboardStatus, TunnelState } from '@ungate/shared/frontend';

interface TunnelStore {
	readonly tunnel: TunnelState;
	readonly busy: boolean;
	readonly error: string | null;
	initialize(): Promise<void>;
	startTunnel(): Promise<void>;
	stopTunnel(): Promise<void>;
	restartTunnel(): Promise<void>;
}

const defaultState: TunnelState = { status: 'stopped', url: null, error: null };

let tunnel = $state<TunnelState>({ ...defaultState });
let busy = $state(false);
let error = $state<string | null>(null);
let initialized = false;

function toTunnelStatus(phase: DashboardStatus['tunnel']['phase']): TunnelState['status'] {
	switch (phase) {
		case 'running':
			return 'running';
		case 'starting':
		case 'stopping':
			return 'starting';
		case 'error':
			return 'error';
		default:
			return 'stopped';
	}
}

function applyStatus(status: DashboardStatus): void {
	tunnel = {
		status: toTunnelStatus(status.tunnel.phase),
		url: status.tunnel.url || null,
		error: status.tunnel.error
	};
}

async function initialize(): Promise<void> {
	if (initialized) return;
	initialized = true;

	dashboardClient.subscribe((event) => {
		if (event.type === 'status') {
			applyStatus(event.data);
		}
	});

	try {
		applyStatus(await dashboardClient.getStatus());
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
		tunnel = { status: 'error', url: null, error };
	}
}

async function runAction(action: DashboardServiceAction): Promise<void> {
	busy = true;
	error = null;

	try {
		const operation = await dashboardClient.controlTunnel(action);
		await dashboardClient.waitForOperation(operation.id);
		applyStatus(await dashboardClient.getStatus());
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
	} finally {
		busy = false;
	}
}

function startTunnel(): Promise<void> {
	return runAction('start');
}

function stopTunnel(): Promise<void> {
	return runAction('stop');
}

function restartTunnel(): Promise<void> {
	return runAction('restart');
}

export function getTunnelStore(): TunnelStore {
	return {
		get tunnel() {
			return tunnel;
		},
		get busy() {
			return busy;
		},
		get error() {
			return error;
		},
		initialize,
		startTunnel,
		stopTunnel,
		restartTunnel
	};
}
