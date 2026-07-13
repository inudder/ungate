import { afterEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
	return {
		installMock: vi.fn(),
		useMock: vi.fn(),
		binExport: '/dev/cloudflared-package/bin/cloudflared'
	};
});

vi.mock('cloudflared', () => {
	return {
		bin: mocks.binExport,
		install: mocks.installMock,
		use: mocks.useMock,
		Tunnel: {
			quick: vi.fn(() => ({
				on: vi.fn(),
				stop: vi.fn()
			}))
		}
	};
});

vi.mock('../../src/runtime-state', () => {
	return {
		RuntimeStateStore: {
			mutate: vi.fn((mutator: (state: unknown) => unknown) => Promise.resolve(mutator({ tunnel: {} }))),
			read: vi.fn(() => ({ clients: {} })),
			hasLiveClients: vi.fn(() => true)
		}
	};
});

import { TunnelManager } from '../../src/tunnel-manager';

describe('TunnelManager NSSM-managed frpc startup', () => {
	afterEach(() => {
		vi.unstubAllGlobals();
		vi.clearAllMocks();
	});

	it('uses the fixed frpc URL without installing cloudflared', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(() => new Promise(() => {}))
		);
		const manager = new TunnelManager(
			'window-a',
			() => true,
			() => {},
			() => {}
		);

		await manager.start(47821);

		expect(manager.getState()).toMatchObject({ status: 'starting', url: 'https://ungate.ahref.cyou', error: null });
		expect(mocks.installMock).not.toHaveBeenCalled();
		expect(mocks.useMock).not.toHaveBeenCalled();

		manager.stop();
	});
});
