import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import net from 'node:net';
import path from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const maxBytes = 1024 * 1024;

export function launcherPipeName(ownerSid: string, betaHome: string): string {
	const full = path.win32.resolve(betaHome);
	const root = path.win32.parse(full).root;
	const canonical = full.length > root.length ? full.replace(/[\\/]+$/, '') : full;
	const hash = createHash('sha256').update(`${ownerSid}|${canonical}`, 'utf8').digest('hex');

	return `ungate-launcher-control-${hash.slice(0, 32)}`;
}

export interface LauncherAgentResponse {
	status: number;
	body: unknown;
	serverPid?: number;
}

export interface LauncherTransport {
	request(action: string, payload: Record<string, unknown>, requestId: string): Promise<LauncherAgentResponse>;
}

async function verifyServer(pid: number, ownerSid: string): Promise<void> {
	if (!Number.isInteger(pid) || pid <= 0) throw new Error('Launcher agent identity is missing.');
	const pidText = String(pid);
	const script = [
		`$process = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=${pidText}')`,
		'if (-not $process) { throw "missing process" }',
		'$owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner',
		'$account = [System.Security.Principal.NTAccount]::new([string]$owner.Domain, [string]$owner.User)',
		'$sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value',
		'[pscustomobject]@{ sid = $sid; executable = [string]$process.ExecutablePath } | ConvertTo-Json -Compress'
	].join('; ');
	const { stdout } = await execFileAsync('pwsh', ['-NoProfile', '-Command', script], { windowsHide: true });
	const identity = JSON.parse(stdout) as { sid?: string; executable?: string };
	const executable = (identity.executable ?? '').toLowerCase();
	if (identity.sid !== ownerSid || !executable.endsWith('pwsh.exe')) {
		throw new Error('Launcher agent process is not the profile owner.');
	}
}

export function createPipeTransport(pipeName: string, ownerSid: string): LauncherTransport {
	let verifiedPid: number | null = null;

	return {
		request(action, payload, requestId) {
			return new Promise((resolve, reject) => {
				const socket = net.connect('\\\\.\\pipe\\' + pipeName);
				const chunks: Buffer[] = [];
				let header: Buffer | null = null;
				const timer = setTimeout(() => {
					socket.destroy();
					reject(new Error('Launcher agent timed out.'));
				}, 10_000);
				socket.once('error', (error) => {
					clearTimeout(timer);
					reject(error);
				});
				socket.on('connect', () => {
					const body = Buffer.from(JSON.stringify({ version: 1, requestId, action, payload }));
					const frame = Buffer.alloc(4 + body.length);
					frame.writeUInt32LE(body.length, 0);
					body.copy(frame, 4);
					socket.write(frame);
				});
				socket.on('data', (chunk: Buffer) => {
					chunks.push(chunk);
					const buffered = Buffer.concat(chunks);
					if (!header && buffered.length >= 4) header = buffered.subarray(0, 4);
					if (!header) return;
					const length = header.readUInt32LE(0);
					if (length > maxBytes) {
						clearTimeout(timer);
						socket.destroy();
						reject(new Error('Launcher response is too large.'));

						return;
					}
					if (buffered.length >= 4 + length) {
						clearTimeout(timer);
						// The agent waits for the client to close before accepting the next connection.
						socket.destroy();
						const parsed = JSON.parse(buffered.subarray(4, 4 + length).toString('utf8')) as LauncherAgentResponse;
						const pid = parsed.serverPid ?? 0;
						const finish = () => resolve(parsed);
						if (verifiedPid === pid) finish();
						else {
							verifyServer(pid, ownerSid)
								.then(() => {
									verifiedPid = pid;
									finish();
								})
								.catch(reject);
						}
					}
				});
			});
		}
	};
}
