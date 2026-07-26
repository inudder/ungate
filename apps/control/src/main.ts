import { loadConfig } from './config';
import { buildServer } from './server';

async function main(): Promise<void> {
	const config = loadConfig();
	const app = await buildServer(config);

	async function shutdown(): Promise<void> {
		try {
			await app.close();
		} finally {
			process.exit(0);
		}
	}

	process.once('SIGINT', () => void shutdown());
	process.once('SIGTERM', () => void shutdown());

	try {
		await app.listen({ host: config.host, port: config.port });
		console.log(`[ungate-dashboard] listening on http://${config.host}:${config.port}`);
	} catch (error) {
		console.error('[ungate-dashboard] failed to start:', error);
		process.exit(1);
	}
}

void main();
