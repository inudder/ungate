import type { DashboardEvent } from '@ungate/shared';
import type { ServerResponse } from 'node:http';

export class EventHub {
	private readonly clients = new Set<ServerResponse>();
	private nextId = 1;
	private heartbeatTimer: NodeJS.Timeout | null = null;

	start(): void {
		if (this.heartbeatTimer) return;

		this.heartbeatTimer = setInterval(() => {
			for (const client of this.clients) {
				client.write(': heartbeat\n\n');
			}
		}, 15_000);
		this.heartbeatTimer.unref();
	}

	add(client: ServerResponse): () => void {
		this.clients.add(client);
		client.write(': connected\n\n');

		return () => {
			this.clients.delete(client);
		};
	}

	broadcast(event: DashboardEvent): void {
		const payload = `id: ${this.nextId++}\nevent: ${event.type}\ndata: ${JSON.stringify(event.data)}\n\n`;

		for (const client of this.clients) {
			client.write(payload);
		}
	}

	close(): void {
		if (this.heartbeatTimer) {
			clearInterval(this.heartbeatTimer);
			this.heartbeatTimer = null;
		}

		for (const client of this.clients) {
			client.end();
		}

		this.clients.clear();
	}
}
