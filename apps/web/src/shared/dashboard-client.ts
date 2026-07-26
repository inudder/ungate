import type {
	DashboardBootstrap,
	DashboardEvent,
	DashboardLogSource,
	DashboardLogsSnapshot,
	DashboardOperation,
	DashboardServiceAction,
	DashboardStatus
} from '@ungate/shared/frontend';

type DashboardEventListener = (event: DashboardEvent) => void;

function sleep(milliseconds: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function responseError(response: Response): Promise<Error> {
	try {
		const payload = (await response.json()) as { error?: string; detail?: string };
		const detail = payload.detail ? `: ${payload.detail}` : '';

		return new Error(payload.error ? `${payload.error}${detail}` : `Request failed: ${response.status}`);
	} catch {
		return new Error(`Request failed: ${response.status}`);
	}
}

class DashboardClient {
	private bootstrapPromise: Promise<DashboardBootstrap> | null = null;
	private bootstrapData: DashboardBootstrap | null = null;
	private eventSource: EventSource | null = null;
	private readonly listeners = new Set<DashboardEventListener>();

	async initialize(): Promise<DashboardBootstrap> {
		return this.ensureBootstrap();
	}

	subscribe(listener: DashboardEventListener): () => void {
		this.listeners.add(listener);
		void this.ensureBootstrap().then((bootstrap) => {
			if (this.listeners.has(listener)) {
				listener({ type: 'status', data: bootstrap.status });
			}
		});

		return () => {
			this.listeners.delete(listener);
		};
	}

	async backend<T>(path: string, init: RequestInit = {}): Promise<T> {
		return this.request<T>(`/api/backend${path}`, init);
	}

	async getStatus(): Promise<DashboardStatus> {
		const response = await fetch('/api/control/status');
		if (!response.ok) throw await responseError(response);

		return response.json() as Promise<DashboardStatus>;
	}

	async getLogs(source: DashboardLogSource): Promise<DashboardLogsSnapshot> {
		const response = await fetch(`/api/control/logs?source=${source}&limit=500`);
		if (!response.ok) throw await responseError(response);

		return response.json() as Promise<DashboardLogsSnapshot>;
	}

	async restartApi(): Promise<DashboardOperation> {
		return this.request('/api/control/api/restart', { method: 'POST' });
	}

	async controlTunnel(action: DashboardServiceAction): Promise<DashboardOperation> {
		return this.request(`/api/control/tunnel/${action}`, { method: 'POST' });
	}

	async waitForOperation(id: string, timeoutMs = 45_000): Promise<DashboardOperation> {
		const deadline = Date.now() + timeoutMs;

		while (Date.now() < deadline) {
			const response = await fetch(`/api/control/operations/${encodeURIComponent(id)}`);
			if (response.ok) {
				const operation = (await response.json()) as DashboardOperation;

				if (operation.state === 'succeeded') return operation;
				if (operation.state === 'failed') throw new Error(operation.error ?? 'Service operation failed');
			}

			await sleep(500);
		}

		throw new Error('Service operation timed out');
	}

	private async request<T>(path: string, init: RequestInit): Promise<T> {
		const bootstrap = await this.ensureBootstrap();
		const headers = new Headers(init.headers);
		headers.set('X-Ungate-CSRF', bootstrap.csrfToken);

		if (init.body !== undefined && !headers.has('Content-Type')) {
			headers.set('Content-Type', 'application/json');
		}

		const response = await fetch(path, { ...init, headers });
		if (!response.ok) throw await responseError(response);

		return response.json() as Promise<T>;
	}

	private async ensureBootstrap(): Promise<DashboardBootstrap> {
		if (this.bootstrapData) return this.bootstrapData;

		this.bootstrapPromise ??= fetch('/api/control/bootstrap')
			.then(async (response) => {
				if (!response.ok) throw await responseError(response);

				return response.json() as Promise<DashboardBootstrap>;
			})
			.then((bootstrap) => {
				this.bootstrapData = bootstrap;
				this.openEventStream(bootstrap.eventsUrl);

				return bootstrap;
			})
			.catch((error) => {
				this.bootstrapPromise = null;
				throw error;
			});

		return this.bootstrapPromise;
	}

	private openEventStream(url: string): void {
		if (this.eventSource) return;

		const source = new EventSource(url);
		this.eventSource = source;

		for (const type of ['status', 'log', 'operation'] as const) {
			source.addEventListener(type, (message) => {
				try {
					const event = {
						type,
						data: JSON.parse((message as MessageEvent<string>).data) as DashboardEvent['data']
					} as DashboardEvent;

					for (const listener of this.listeners) {
						listener(event);
					}
				} catch {
					// A malformed event is ignored; EventSource will continue receiving.
				}
			});
		}
	}
}

export const dashboardClient = new DashboardClient();
