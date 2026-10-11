import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const controlRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const session = 'ungate-dashboard-qa';
const pwshPath = process.env.PWSH_PATH ?? 'C:\\Program Files\\PowerShell\\7\\pwsh.exe';
const browserPath =
	process.env.AGENT_BROWSER_PATH ?? 'C:\\Users\\kalvinclein\\AppData\\Roaming\\npm\\agent-browser.ps1';
const output = [];
let origin = '';

async function waitForAssignedOrigin() {
	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline) {
		const text = output.join('');
		const marker = 'listening on http://127.0.0.1:';
		const index = text.indexOf(marker);
		if (index >= 0) {
			const port = text.slice(index + marker.length).match(/^(\d+)/);
			if (port) return 'http://127.0.0.1:' + port[1];
		}
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	throw new Error('Dashboard did not report an assigned port.');
}

const child = spawn(process.execPath, ['bundle/main.cjs'], {
	cwd: controlRoot,
	env: {
		...process.env,
		PORT: '0',
		NSSM_PATH:
			process.env.NSSM_PATH ??
			'C:\\Users\\kalvinclein\\scoop\\apps\\nssm\\current\\nssm.exe',
	},
	stdio: ['ignore', 'pipe', 'pipe'],
	windowsHide: true,
});

child.stdout.on('data', (chunk) => output.push(chunk.toString()));
child.stderr.on('data', (chunk) => output.push(chunk.toString()));

function browser(...args) {
	const result = spawnSync(
		pwshPath,
		['-NoProfile', '-File', browserPath, '--session', session, ...args],
		{
			cwd: controlRoot,
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe'],
			timeout: 30_000,
			windowsHide: true,
		},
	);

	if (result.stdout) process.stdout.write(result.stdout);
	if (result.status !== 0) {
		throw new Error(
			`agent-browser ${args.join(' ')} failed: ${result.stderr || `exit ${result.status}`}`,
		);
	}
}

async function waitForHealth(attempts = 40) {
	let lastError;

	for (let attempt = 0; attempt < attempts; attempt += 1) {
		try {
			const response = await fetch(`${origin}/health`);
			if (response.ok) return;
			lastError = new Error(`Health returned HTTP ${response.status}`);
		} catch (error) {
			lastError = error;
		}

		await new Promise((resolve) => setTimeout(resolve, 250));
	}

	throw lastError;
}

try {
	origin = await waitForAssignedOrigin();
	await waitForHealth();
	browser('open', origin);
	browser('wait', '--text', 'Ungate');
	browser('snapshot', '-i', '-u');
	browser('find', 'role', 'button', 'click', '--name', 'Settings');
	browser('wait', '--text', 'Wake Ping');
	browser('find', 'role', 'button', 'click', '--name', 'Logs');
	browser('wait', '--text', 'API Logs');
	browser('snapshot', '-i');
	browser('errors');
	console.log(JSON.stringify({ browser: 'ok' }));
} catch (error) {
	const processOutput = output.join('').trim();
	if (processOutput) {
		console.error(processOutput);
	}
	throw error;
} finally {
	try {
		browser('close');
	} catch {
		// Preserve the primary failure if the browser session already ended.
	}

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
