import { beforeEach, describe, expect, it, vi } from 'vitest';

import { ApiServer } from '../../src/api-server';

import { TestHelper } from './helpers/test-helper';

import type { RuntimeState } from '@ungate/shared/frontend';

const {
	runtimeReadMock,
	runtimeHasLiveClientsMock,
	runtimeMutateMock,
	sleepMock,
	nssmRestartMock,
	settingsInitMock,
	settingsReadPortMock
} = vi.hoisted(() => {
	const runtimeReadMock = vi.fn<() => RuntimeState>();
	const runtimeHasLiveClientsMock = vi.fn<(state: RuntimeState) => boolean>();
	const runtimeMutateMock = vi.fn<(mutator: (current: RuntimeState) => RuntimeState) => Promise<RuntimeState>>();
	const sleepMock = vi.fn<(ms: number) => Promise<void>>().mockResolvedValue(undefined);
	const nssmRestartMock = vi.fn<() => Promise<void>>().mockResolvedValue(undefined);
	const settingsInitMock = vi.fn<() => Promise<string | null>>().mockResolvedValue(null);
	const settingsReadPortMock = vi.fn<() => Promise<number | null>>().mockResolvedValue(null);

	return {
		runtimeReadMock,
		runtimeHasLiveClientsMock,
		runtimeMutateMock,
		sleepMock,
		nssmRestartMock,
		settingsInitMock,
		settingsReadPortMock
	};
});

vi.mock('../../src/utils/nssm-service', () => {
	return {
		NssmService: {
			restart: (...args: unknown[]) => nssmRestartMock(...args)
		}
	};
});

vi.mock('../../src/utils/ungate-settings-reader', () => {
	return {
		UngateSettingsReader: class {
			init() {
				return settingsInitMock();
			}

			readPort() {
				return settingsReadPortMock();
			}
		}
	};
});

vi.mock('@ungate/shared', () => {
	return {
		sleep: sleepMock
	};
});

vi.mock('vscode', () => {
	return {
		ExtensionMode: {
			Development: 1,
			Production: 2
		}
	};
});

const isApiStartSuppressedMock = vi.fn<() => boolean>(() => false);
const suppressApiAutoStartMock = vi.fn<() => Promise<void>>(() => Promise.resolve());
const resetApiForRestartMock = vi.fn<() => Promise<void>>(() => Promise.resolve());

vi.mock('../../src/runtime-state', () => {
	return {
		RuntimeStateStore: {
			read: runtimeReadMock,
			hasLiveClients: runtimeHasLiveClientsMock,
			mutate: runtimeMutateMock,
			isApiStartSuppressed: (...args: unknown[]) => isApiStartSuppressedMock(...args),
			suppressApiAutoStart: (...args: unknown[]) => suppressApiAutoStartMock(...args),
			resetApiForRestart: (...args: unknown[]) => resetApiForRestartMock(...args)
		}
	};
});

interface ApiServerInternals {
	port: number | null;
	lastStatus: 'starting' | 'running' | 'stopped' | 'error' | null;
	startPromise: Promise<void> | null;
	consecutiveFailures: number;
	healthCheckInFlight: boolean;
	runHealthCheckCycle(): Promise<void>;
	checkPortHealth(port: number): Promise<boolean>;
	startHealthCheck(): void;
	stopHealthCheck(): void;
	resolvePort(): Promise<number>;
	pollUntilHealthy(port: number): Promise<boolean>;
}

function createRuntimeState(): RuntimeState {
	return TestHelper.createRuntimeState([], 4783);
}

function getInternals(server: InstanceType<typeof ApiServer>): ApiServerInternals {
	return server as unknown as ApiServerInternals;
}

function createServer(options?: { isLeaderWindow?: boolean; isExtensionHostActive?: boolean }): {
	server: InstanceType<typeof ApiServer>;
	onStatusChange: ReturnType<typeof vi.fn>;
	onPortDetected: ReturnType<typeof vi.fn>;
	onLog: ReturnType<typeof vi.fn>;
} {
	const onStatusChange = vi.fn();
	const onPortDetected = vi.fn();
	const onLog = vi.fn();
	const server = new ApiServer(
		{
			extensionMode: 1,
			extensionPath: '/tmp/ungate-extension'
		} as never,
		{
			onLog,
			onPortDetected,
			onStatusChange,
			isLeaderWindow() {
				return options?.isLeaderWindow ?? true;
			},
			isExtensionHostActive() {
				return options?.isExtensionHostActive ?? true;
			},
			getWindowId() {
				return 'test-window';
			}
		}
	);

	return { server, onStatusChange, onPortDetected, onLog };
}

describe('ApiServer.start (attach-only)', () => {
	beforeEach(() => {
		runtimeReadMock.mockReset();
		runtimeHasLiveClientsMock.mockReset();
		runtimeMutateMock.mockReset();
		isApiStartSuppressedMock.mockReset();
		isApiStartSuppressedMock.mockReturnValue(false);
		suppressApiAutoStartMock.mockReset();
		resetApiForRestartMock.mockReset();
		sleepMock.mockReset();
		sleepMock.mockResolvedValue(undefined);
		nssmRestartMock.mockReset();
		nssmRestartMock.mockResolvedValue(undefined);
		settingsInitMock.mockReset();
		settingsInitMock.mockResolvedValue(null);
		settingsReadPortMock.mockReset();
		settingsReadPortMock.mockResolvedValue(null);
		vi.unstubAllGlobals();
		vi.useRealTimers();
	});

	it('attaches to an existing healthy api from runtime state without spawning', async () => {
		const runtimeState = createRuntimeState();
		const { server, onPortDetected, onStatusChange } = createServer();
		runtimeReadMock.mockReturnValue(runtimeState);
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(structuredClone(runtimeState)));
		});
		vi.spyOn(getInternals(server), 'checkPortHealth').mockResolvedValue(true);
		vi.spyOn(getInternals(server), 'startHealthCheck').mockImplementation(() => {});

		await server.start();

		expect(onPortDetected).toHaveBeenCalledWith(4783);
		expect(onStatusChange).toHaveBeenCalledWith('running');
	});

	it('does not start when api start is suppressed', async () => {
		isApiStartSuppressedMock.mockReturnValue(true);
		const { server, onStatusChange } = createServer();

		await server.start();

		expect(onStatusChange).not.toHaveBeenCalledWith('running');
	});

	it('resolves port from app_settings DB when runtime state has no port', async () => {
		const runtimeState = TestHelper.createRuntimeState([], null);
		const { server, onPortDetected } = createServer();
		runtimeReadMock.mockReturnValue(runtimeState);
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(structuredClone(runtimeState)));
		});
		settingsReadPortMock.mockResolvedValue(47821);
		vi.spyOn(getInternals(server), 'checkPortHealth').mockResolvedValue(true);
		vi.spyOn(getInternals(server), 'startHealthCheck').mockImplementation(() => {});

		await server.start();

		expect(settingsReadPortMock).toHaveBeenCalledTimes(1);
		expect(onPortDetected).toHaveBeenCalledWith(47821);
	});

	it('falls back to default port 47821 when DB returns null', async () => {
		const runtimeState = TestHelper.createRuntimeState([], null);
		const { server, onPortDetected } = createServer();
		runtimeReadMock.mockReturnValue(runtimeState);
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(structuredClone(runtimeState)));
		});
		settingsReadPortMock.mockResolvedValue(null);
		vi.spyOn(getInternals(server), 'checkPortHealth').mockResolvedValue(true);
		vi.spyOn(getInternals(server), 'startHealthCheck').mockImplementation(() => {});

		await server.start();

		expect(onPortDetected).toHaveBeenCalledWith(47821);
	});

	it('records failure when service never becomes healthy', async () => {
		const runtimeState = TestHelper.createRuntimeState([], null);
		const { server, onStatusChange } = createServer();
		runtimeReadMock.mockReturnValue(runtimeState);
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(structuredClone(runtimeState)));
		});
		vi.spyOn(getInternals(server), 'pollUntilHealthy').mockResolvedValue(false);

		await server.start();

		expect(suppressApiAutoStartMock).toHaveBeenCalledTimes(1);
		expect(onStatusChange).toHaveBeenCalledWith('error');
	});

	it('deduplicates parallel start calls', async () => {
		const runtimeState = createRuntimeState();
		const { server } = createServer();
		runtimeReadMock.mockReturnValue(runtimeState);
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(structuredClone(runtimeState)));
		});

		let releaseHealth: (() => void) | undefined;
		const checkPortHealthSpy = vi.spyOn(getInternals(server), 'checkPortHealth').mockImplementation(() => {
			return new Promise<boolean>((resolve) => {
				releaseHealth = () => resolve(true);
			});
		});
		vi.spyOn(getInternals(server), 'startHealthCheck').mockImplementation(() => {});

		const first = server.start();
		const second = server.start();

		expect(server.isStartupInProgress()).toBe(true);

		releaseHealth?.();
		await Promise.all([first, second]);

		// checkPortHealth called once (deduplicated), not twice
		expect(checkPortHealthSpy).toHaveBeenCalledTimes(1);
	});

	it('does not re-attach when port is already set', async () => {
		const { server, onPortDetected } = createServer();
		const internals = getInternals(server);
		internals.port = 4783;

		const healthSpy = vi.spyOn(internals, 'checkPortHealth');

		await server.start();

		expect(healthSpy).not.toHaveBeenCalled();
		expect(onPortDetected).not.toHaveBeenCalled();
	});
});

describe('ApiServer.restart (NSSM)', () => {
	beforeEach(() => {
		runtimeReadMock.mockReset();
		runtimeMutateMock.mockReset();
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(createRuntimeState()));
		});
		resetApiForRestartMock.mockReset();
		resetApiForRestartMock.mockResolvedValue(undefined);
		nssmRestartMock.mockReset();
		nssmRestartMock.mockResolvedValue(undefined);
		settingsInitMock.mockReset();
		settingsInitMock.mockResolvedValue(null);
		settingsReadPortMock.mockReset();
		settingsReadPortMock.mockResolvedValue(47821);
		sleepMock.mockReset();
		sleepMock.mockResolvedValue(undefined);
	});

	it('calls nssm restart and re-attaches to the service', async () => {
		const { server, onPortDetected, onStatusChange } = createServer();
		vi.spyOn(getInternals(server), 'checkPortHealth').mockResolvedValue(true);
		vi.spyOn(getInternals(server), 'startHealthCheck').mockImplementation(() => {});

		await server.restart();

		expect(nssmRestartMock).toHaveBeenCalledWith('ungate-api');
		expect(onPortDetected).toHaveBeenCalledWith(47821);
		expect(onStatusChange).toHaveBeenCalledWith('running');
	});

	it('records failure when service does not become healthy after restart', async () => {
		const { server, onStatusChange } = createServer();
		vi.spyOn(getInternals(server), 'pollUntilHealthy').mockResolvedValue(false);

		await server.restart();

		expect(nssmRestartMock).toHaveBeenCalledWith('ungate-api');
		expect(suppressApiAutoStartMock).toHaveBeenCalledTimes(1);
		expect(onStatusChange).toHaveBeenCalledWith('error');
	});
});

describe('ApiServer.stop', () => {
	beforeEach(() => {
		runtimeReadMock.mockReset();
		runtimeMutateMock.mockReset();
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(createRuntimeState()));
		});
		isApiStartSuppressedMock.mockReset();
		isApiStartSuppressedMock.mockReturnValue(false);
	});

	it('stops health check and detaches without overwriting shared state (NSSM keeps running)', async () => {
		const { server, onStatusChange } = createServer();
		const internals = getInternals(server);
		internals.port = 4783;
		const stopHealthSpy = vi.spyOn(internals, 'stopHealthCheck').mockImplementation(() => {});

		await server.stop();

		expect(stopHealthSpy).toHaveBeenCalledTimes(1);
		expect(internals.port).toBeNull();
		expect(onStatusChange).toHaveBeenCalledWith('stopped');
		// NSSM-managed service keeps running — detach must not falsify shared state.
		expect(runtimeMutateMock).not.toHaveBeenCalled();
	});

	it('sets error status when api start is suppressed', async () => {
		isApiStartSuppressedMock.mockReturnValue(true);
		const { server, onStatusChange } = createServer();

		await server.stop();

		expect(onStatusChange).not.toHaveBeenCalledWith('stopped');
	});
});

describe('ApiServer.runHealthCheckCycle', () => {
	beforeEach(() => {
		runtimeReadMock.mockReset();
		runtimeHasLiveClientsMock.mockReset();
		runtimeMutateMock.mockReset();
		runtimeMutateMock.mockImplementation((mutator) => {
			return Promise.resolve(mutator(createRuntimeState()));
		});
		isApiStartSuppressedMock.mockReset();
		isApiStartSuppressedMock.mockReturnValue(false);
		suppressApiAutoStartMock.mockReset();
		vi.unstubAllGlobals();
		vi.useRealTimers();
	});

	it('marks status as running when health check succeeds', async () => {
		const { server, onStatusChange } = createServer();
		const internals = getInternals(server);
		internals.port = 4783;
		internals.lastStatus = 'error';

		vi.stubGlobal(
			'fetch',
			vi.fn(() => Promise.resolve({ ok: true }))
		);

		await internals.runHealthCheckCycle();

		expect(onStatusChange).toHaveBeenCalledWith('running');
	});

	it('marks status as error after threshold consecutive failures (non-ok status)', async () => {
		const { server, onStatusChange } = createServer();
		const internals = getInternals(server);
		internals.port = 4783;
		internals.lastStatus = 'running';

		vi.stubGlobal(
			'fetch',
			vi.fn(() => Promise.resolve({ ok: false, status: 502 }))
		);

		// Below threshold — no error yet
		await internals.runHealthCheckCycle();
		await internals.runHealthCheckCycle();
		expect(suppressApiAutoStartMock).not.toHaveBeenCalled();

		// Third consecutive failure — now declares error
		await internals.runHealthCheckCycle();
		expect(suppressApiAutoStartMock).toHaveBeenCalledTimes(1);
		expect(onStatusChange).toHaveBeenCalledWith('error');
	});

	it('marks status as error after threshold consecutive failures (throw)', async () => {
		const { server, onStatusChange } = createServer();
		const internals = getInternals(server);
		internals.port = 4783;
		internals.lastStatus = 'running';

		vi.stubGlobal(
			'fetch',
			vi.fn(() => Promise.reject(new Error('connection refused')))
		);

		await internals.runHealthCheckCycle();
		await internals.runHealthCheckCycle();
		expect(suppressApiAutoStartMock).not.toHaveBeenCalled();

		await internals.runHealthCheckCycle();
		expect(suppressApiAutoStartMock).toHaveBeenCalledTimes(1);
		expect(onStatusChange).toHaveBeenCalledWith('error');
	});

	it('does not auto-stop api when no live clients remain (NSSM manages lifecycle)', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(0);

		const runtimeState = createRuntimeState();
		const { server } = createServer({ isExtensionHostActive: false });
		const internals = getInternals(server);
		runtimeReadMock.mockReturnValue(runtimeState);
		runtimeHasLiveClientsMock.mockReturnValue(false);
		internals.port = 4783;
		internals.lastStatus = 'running';

		vi.stubGlobal(
			'fetch',
			vi.fn(() => Promise.resolve({ ok: true }))
		);
		const stopSpy = vi.spyOn(server, 'stop').mockResolvedValue(undefined);

		await internals.runHealthCheckCycle();
		vi.setSystemTime(10000);
		await internals.runHealthCheckCycle();

		// NSSM service keeps running — extension must not stop it
		expect(stopSpy).not.toHaveBeenCalled();
	});

	it('skips health check when not leader window', async () => {
		const { server } = createServer({ isLeaderWindow: false });
		const internals = getInternals(server);
		internals.port = 4783;

		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);

		await internals.runHealthCheckCycle();

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('skips health check when port is not set', async () => {
		const { server } = createServer();
		const internals = getInternals(server);
		internals.port = null;

		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);

		await internals.runHealthCheckCycle();

		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('resets failure counter on success and does not flicker on transient blips', async () => {
		const { server, onStatusChange } = createServer();
		const internals = getInternals(server);
		internals.port = 4783;
		internals.lastStatus = 'running';

		let shouldFail = true;
		vi.stubGlobal(
			'fetch',
			vi.fn(() => (shouldFail ? Promise.resolve({ ok: false, status: 502 }) : Promise.resolve({ ok: true })))
		);

		// Two failures — below threshold, no error
		await internals.runHealthCheckCycle();
		await internals.runHealthCheckCycle();
		expect(suppressApiAutoStartMock).not.toHaveBeenCalled();

		// Success — counter resets
		shouldFail = false;
		await internals.runHealthCheckCycle();
		expect(onStatusChange).toHaveBeenCalledWith('running');

		// Two more failures — still below threshold (counter was reset)
		shouldFail = true;
		await internals.runHealthCheckCycle();
		await internals.runHealthCheckCycle();
		expect(suppressApiAutoStartMock).not.toHaveBeenCalled();
	});

	it('skips overlapping health check cycles while one is in flight', async () => {
		const { server } = createServer();
		const internals = getInternals(server);
		internals.port = 4783;

		let releaseFetch: (() => void) | undefined;
		vi.stubGlobal(
			'fetch',
			vi.fn(
				() =>
					new Promise((resolve) => {
						releaseFetch = () => resolve({ ok: true });
					})
			)
		);

		const fetchMock = vi.mocked(fetch);

		// Start first cycle — don't await yet; fetch is pending, inFlight=true
		const first = internals.runHealthCheckCycle();
		expect(fetchMock).toHaveBeenCalledTimes(1);

		// Second call while first is in flight — must be skipped (no new fetch)
		await internals.runHealthCheckCycle();
		expect(fetchMock).toHaveBeenCalledTimes(1);

		releaseFetch?.();
		await first;
	});
});
