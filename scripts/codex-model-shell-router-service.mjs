import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { constants, writeSync } from 'node:fs';
import { copyFile, mkdir, readFile, readdir, rename, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createShellRouterServer, SERVICE_NAME } from './codex-model-shell-router.mjs';
import { safeFailureDetails } from './codex-shell-router-supervisor.mjs';

const runtimeDirectory = path.dirname(fileURLToPath(import.meta.url));
const defaultRoot = 'C:\\ProgramData\\Ungate\\shell-router';
const maxEnvelopeBytes = 2 * 1024 * 1024;
const revisionPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function log(event, fields = {}) {
	console.log(JSON.stringify({ timestamp: new Date().toISOString(), service: SERVICE_NAME, event, ...fields }));
}

function fatal(event, error) {
	try {
		writeSync(
			1,
			`${JSON.stringify({ timestamp: new Date().toISOString(), service: SERVICE_NAME, event, ...safeFailureDetails(error) })}\n`
		);
	} catch {
		/* NSSM will still observe the failing exit. */
	}
	process.exit(1);
}

export function decryptEnvelope(ciphertext) {
	return new Promise((resolve, reject) => {
		const program = 'C:\\Program Files\\PowerShell\\7\\pwsh.exe';
		const worker = path.join(runtimeDirectory, 'codex-shell-router-dpapi.ps1');
		const child = spawn(program, ['-NoProfile', '-NonInteractive', '-File', worker], {
			windowsHide: true,
			stdio: ['pipe', 'pipe', 'pipe']
		});
		let output = '';
		let settled = false;
		const finish = (error, value) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			if (error instanceof Error) reject(error);
			else resolve(value);
		};
		const timer = setTimeout(() => {
			child.kill();
			finish(new Error('decrypt_timeout'));
		}, 15000);
		child.stdout.setEncoding('utf8');
		child.stdout.on('data', (chunk) => {
			output += chunk;
			if (output.length > maxEnvelopeBytes * 2) {
				child.kill();
				finish(new Error('decrypt_output_too_large'));
			}
		});
		// Never forward helper output or exception text to the service log.
		child.stderr.resume();
		child.on('error', () => finish(new Error('decrypt_worker_failed')));
		child.on('close', (code) => {
			if (code !== 0) return finish(new Error('decrypt_failed'));
			try {
				const decoded = Buffer.from(output.trim(), 'base64');
				if (!decoded.length || decoded.length > maxEnvelopeBytes) throw new Error('invalid_size');
				finish(null, JSON.parse(decoded.toString('utf8')));
			} catch {
				finish(new Error('invalid_envelope'));
			}
		});
		child.stdin.on('error', () => finish(new Error('decrypt_worker_failed')));
		child.stdin.end(`${ciphertext.toString('base64')}\n`);
	});
}

async function readEnvelope(file) {
	const info = await stat(file);
	if (!info.isFile() || info.size === 0 || info.size > maxEnvelopeBytes) throw new Error('invalid_envelope');

	const ciphertext = await readFile(file);

	return decryptEnvelope(ciphertext);
}

function validateEnvelope(envelope, expectedRevision, allowExpired = false) {
	if (
		!envelope ||
		typeof envelope !== 'object' ||
		!revisionPattern.test(envelope.revision ?? '') ||
		(expectedRevision && envelope.revision !== expectedRevision)
	)
		throw new Error('invalid_envelope');
	if (!allowExpired && (!Number.isFinite(Date.parse(envelope.expiresAt)) || Date.parse(envelope.expiresAt) < Date.now())) {
		throw new Error('expired_envelope');
	}
	if (!['config', 'drain', 'resume'].includes(envelope.action)) throw new Error('invalid_envelope');
	if (envelope.action === 'config') {
		if (
			!Array.isArray(envelope.routes) ||
			typeof envelope.toolsCachePath !== 'string' ||
			!path.win32.isAbsolute(envelope.toolsCachePath) ||
			path.win32.basename(envelope.toolsCachePath).toLowerCase() !== 'tools-schema-cache.json'
		) {
			throw new Error('invalid_configuration');
		}
	}
}

export async function startShellRouterService({ root = defaultRoot, port = 8319, decrypt = readEnvelope } = {}) {
	const configDir = path.join(root, 'config');
	const activeFile = path.join(configDir, 'active.bin');
	const backupDir = path.join(configDir, 'backups');
	const rejectedDir = path.join(configDir, 'rejected');
	const processedDir = path.join(configDir, 'processed');
	for (const dir of [configDir, backupDir, rejectedDir, processedDir]) await mkdir(dir, { recursive: true });
	const routerSource = await readFile(path.join(runtimeDirectory, 'codex-model-shell-router.mjs'));
	const buildId = createHash('sha256').update(routerSource).digest('hex');
	const server = createShellRouterServer({ buildId });
	const fail = (revision, error) => {
		const allowed = new Set([
			'decrypt_timeout',
			'decrypt_worker_failed',
			'decrypt_failed',
			'invalid_envelope',
			'expired_envelope',
			'invalid_configuration',
			'config_storage_error'
		]);
		const code = allowed.has(error?.message) ? error.message : 'invalid_configuration';
		server.shellRouter.fail(revision, code);
		log('configuration_error', { revision, code });
	};
	try {
		const active = await decrypt(activeFile);
		validateEnvelope(active, null, true);
		if (active.action !== 'config') throw new Error('invalid_configuration');
		server.shellRouter.activate(server.shellRouter.prepare(active), active.revision);
		log('configuration_loaded', { revision: active.revision });
	} catch (error) {
		if (error?.code !== 'ENOENT') fail(null, error);
		else log('configuration_missing');
	}

	let busy = false;
	const scan = async () => {
		if (busy) return;
		busy = true;
		try {
			const directoryEntries = await readdir(configDir);
			const names = directoryEntries.filter((name) => /^pending-[0-9a-f-]+\.bin$/i.test(name)).sort();
			for (const name of names) {
				const revision = name.slice(8, -4);
				const candidate = path.join(configDir, name);
				try {
					if (!revisionPattern.test(revision)) throw new Error('invalid_envelope');
					const envelope = await decrypt(candidate);
					validateEnvelope(envelope, revision);
					if (envelope.action === 'config') {
						const prepared = server.shellRouter.prepare(envelope);
						try {
							await copyFile(activeFile, path.join(backupDir, `${Date.now()}-${randomUUID()}.bin`), constants.COPYFILE_EXCL);
						} catch (error) {
							if (error?.code !== 'ENOENT') throw new Error('config_storage_error');
						}
						try {
							await rename(candidate, activeFile);
						} catch {
							throw new Error('config_storage_error');
						}
						server.shellRouter.activate(prepared, revision);
						log('configuration_activated', { revision, route_count: envelope.routes.length });
					} else {
						server.shellRouter.command(envelope.action, revision, envelope.leaseMs);
						await rename(candidate, path.join(processedDir, name));
						log('control_applied', { revision, action: envelope.action });
					}
				} catch (error) {
					fail(revision, error);
					try {
						await rename(candidate, path.join(rejectedDir, name));
					} catch {
						/* Retain the candidate in place. */
					}
				}
			}
		} catch {
			log('config_scan_failed');
		} finally {
			busy = false;
		}
	};
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(port, '127.0.0.1', resolve);
	});
	const interval = setInterval(() => {
		void scan();
	}, 500);
	server.once('close', () => clearInterval(interval));
	log('listening', { host: '127.0.0.1', port: server.address().port, build_id: buildId });

	return server;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	process.on('uncaughtException', (error) => fatal('uncaught_exception', error));
	process.on('unhandledRejection', (error) => fatal('unhandled_rejection', error));
	startShellRouterService()
		.then((server) => {
			server.on('error', (error) => fatal('listener_error', error));
			for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close(() => process.exit(0)));
		})
		.catch((error) => fatal('startup_failed', error));
}
