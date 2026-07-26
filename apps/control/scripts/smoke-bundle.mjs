import { once } from 'node:events';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const controlRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const port = 47819;
const origin = `http://127.0.0.1:${port}`;
const output = [];

const child = spawn(process.execPath, ['bundle/main.cjs'], {
	cwd: controlRoot,
	env: {
		...process.env,
		PORT: String(port),
		NSSM_PATH:
			process.env.NSSM_PATH ??
			'C:\\Users\\kalvinclein\\scoop\\apps\\nssm\\current\\nssm.exe',
	},
	stdio: ['ignore', 'pipe', 'pipe'],
	windowsHide: true,
});

child.stdout.on('data', (chunk) => output.push(chunk.toString()));
child.stderr.on('data', (chunk) => output.push(chunk.toString()));

async function fetchWithRetry(url, attempts = 40) {
	let lastError;

	for (let attempt = 0; attempt < attempts; attempt += 1) {
		try {
			const response = await fetch(url);
			if (response.ok) {
				return response;
			}
			lastError = new Error(`${url} returned HTTP ${response.status}`);
		} catch (error) {
			lastError = error;
		}

		await new Promise((resolve) => setTimeout(resolve, 250));
	}

	throw lastError;
}

try {
	const healthResponse = await fetchWithRetry(`${origin}/health`);
	const rootResponse = await fetchWithRetry(origin);
	const statusResponse = await fetchWithRetry(`${origin}/api/control/status`);

	const health = await healthResponse.json();
	const status = await statusResponse.json();
	const html = await rootResponse.text();

	if (health.status !== 'ok') {
		throw new Error(`Unexpected health payload: ${JSON.stringify(health)}`);
	}
	if (!html.includes('<div id="app">')) {
		throw new Error('Dashboard HTML does not contain the Svelte mount point.');
	}
	if (!status.dashboard || !status.api || !status.tunnel) {
		throw new Error(`Unexpected status payload: ${JSON.stringify(status)}`);
	}

	console.log(
		JSON.stringify({
			health: health.status,
			html: 'ok',
			statusKeys: Object.keys(status),
		}),
	);
} catch (error) {
	const processOutput = output.join('').trim();
	if (processOutput) {
		console.error(processOutput);
	}
	throw error;
} finally {
	if (child.exitCode === null) {
		child.kill('SIGTERM');
		await Promise.race([
			once(child, 'exit'),
			new Promise((resolve) => setTimeout(resolve, 2_000)),
		]);
	}
	if (child.exitCode === null) {
		child.kill('SIGKILL');
	}
}
