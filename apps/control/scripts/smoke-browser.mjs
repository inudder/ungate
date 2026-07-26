import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const controlRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const port = 47819;
const origin = `http://127.0.0.1:${port}`;
const session = 'ungate-dashboard-qa';
const pwshPath = process.env.PWSH_PATH ?? 'C:\\Program Files\\PowerShell\\7\\pwsh.exe';
const browserPath =
	process.env.AGENT_BROWSER_PATH ?? 'C:\\Users\\kalvinclein\\AppData\\Roaming\\npm\\agent-browser.ps1';
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
