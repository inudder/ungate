import { spawn, execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { promisify } from 'node:util';

import { compareContracts, filterTools, ToolLedger } from './codex-tool-test-contract.mjs';
import { schemaHash } from './codex-tools-schema-cache.mjs';

const execFileAsync = promisify(execFile);

export class DiagnosticError extends Error {
	constructor(code, message) {
		super(message);
		this.code = code;
	}
}

export async function inspectRuntime(configuration) {
	if (!configuration?.executable || (!configuration.modelInfo && (!configuration.catalogPath || !configuration.catalogSlug))) {
		throw new DiagnosticError(
			'runtime_unavailable',
			configuration?.error ?? 'Beta executable and model catalogue are required for execution tests.'
		);
	}
	const { stdout } = await execFileAsync(configuration.executable, ['--version'], { windowsHide: true, timeout: 10000 });
	const catalogText = configuration.modelInfo ? null : await readFile(configuration.catalogPath, 'utf8');
	const catalog = catalogText ? JSON.parse(catalogText) : null;
	const model = configuration.modelInfo ?? catalog.models?.find((entry) => entry.slug === configuration.catalogSlug);
	if (!model) throw new DiagnosticError('runtime_unavailable', 'Selected model is missing from the Beta catalogue.');

	return { executable: configuration.executable, version: stdout.trim(), model: structuredClone(model) };
}

export class RpcClient {
	constructor(child, { signal, onRequest = () => null } = {}) {
		this.child = child;
		this.pending = new Map();
		this.notifications = [];
		this.waiters = new Set();
		this.nextId = 1;
		this.closed = false;
		this.lines = readline.createInterface({ input: child.stdout });
		this.lines.on('line', (line) => {
			let message;
			try {
				message = JSON.parse(line);
			} catch {
				this.fail(new DiagnosticError('invalid_response', 'app-server emitted invalid JSON.'));

				return;
			}
			if (message.method && message.id !== undefined) {
				Promise.resolve(onRequest(message)).then(
					(result) => this.send({ id: message.id, result }),
					() => this.send({ id: message.id, error: { code: -32603, message: 'Diagnostic request handler failed.' } })
				);
			} else if (message.id !== undefined) {
				const pending = this.pending.get(message.id);
				if (!pending) return;
				this.pending.delete(message.id);
				if (message.error) pending.reject(new DiagnosticError('runtime_error', message.error.message));
				else pending.resolve(message.result);
			} else {
				this.notifications.push(message);
				for (const waiter of [...this.waiters]) {
					if (waiter.predicate(message)) {
						this.waiters.delete(waiter);
						waiter.resolve(message);
					}
				}
			}
		});
		child.once('error', (error) => this.fail(error));
		child.once('exit', (code, signal) =>
			this.fail(new DiagnosticError('runtime_error', `app-server exited (code ${code}, signal ${signal}).`))
		);
		this.abort = () => this.fail(new DiagnosticError('cancelled', 'Execution test aborted.'));
		this.signal = signal;
		signal?.addEventListener('abort', this.abort, { once: true });
		if (signal?.aborted) this.abort();
	}

	send(message) {
		if (!this.child.stdin.destroyed) this.child.stdin.write(`${JSON.stringify(message)}\n`);
	}

	request(method, params) {
		if (this.closed) throw this.failure;
		const id = this.nextId++;

		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject });
			this.send({ id, method, params });
		});
	}

	wait(predicate) {
		const existing = this.notifications.find(predicate);
		if (existing) return Promise.resolve(existing);
		if (this.closed) throw this.failure;

		return new Promise((resolve, reject) => this.waiters.add({ predicate, resolve, reject }));
	}

	fail(error) {
		this.closed = true;
		this.failure = error;
		for (const entry of [...this.pending.values(), ...this.waiters]) entry.reject(error);
		this.pending.clear();
		this.waiters.clear();
	}

	dispose() {
		this.signal?.removeEventListener('abort', this.abort);
		this.lines.close();
		this.fail(new DiagnosticError('cancelled', 'Diagnostic session closed.'));
	}
}

function childEnvironment(directory, token) {
	const allowed =
		/^(PATH|PATHEXT|SystemRoot|WINDIR|COMSPEC|TEMP|TMP|USERPROFILE|APPDATA|LOCALAPPDATA|ProgramFiles(?:\(x86\))?|ProgramData|PSModulePath|SystemDrive|NUMBER_OF_PROCESSORS|PROCESSOR_ARCHITECTURE|LANG|LC_ALL)$/i;
	const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => allowed.test(key)));

	return { ...environment, CODEX_HOME: directory, UNGATE_DIAGNOSTIC_TOKEN: token };
}

export async function stopOwnedChild(child) {
	if (!child?.pid) return;
	if (child.exitCode !== null || child.signalCode) return;
	child.stdin.end();
	const exited = new Promise((resolve) => child.once('exit', resolve));
	let timer;
	await Promise.race([
		exited,
		new Promise((resolve) => {
			timer = setTimeout(resolve, 10000);
		})
	]);
	clearTimeout(timer);
	if (child.exitCode !== null || child.signalCode) return;
	if (process.platform === 'win32') {
		await execFileAsync('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, timeout: 10000 }).catch(
			() => {}
		);
	} else child.kill('SIGKILL');
	await Promise.race([
		exited,
		new Promise((resolve) => {
			timer = setTimeout(resolve, 1000);
		})
	]);
	clearTimeout(timer);
	if (child.exitCode === null && !child.signalCode) {
		throw new DiagnosticError('cleanup_failed', 'Owned app-server did not stop.');
	}
}

export class CodexTestRuntime {
	constructor({ runtime, baseUrl, snapshot, names, signal, requestTimeoutMs = 120000, autoAnswer, onProgress = async () => {} }) {
		Object.assign(this, { runtime, baseUrl, snapshot, signal, requestTimeoutMs, autoAnswer, onProgress });
		this.names = new Set(names);
		this.ledger = new ToolLedger(names);
		this.contracts = [];
		this.autoAnswers = [];
		this.failure = null;
		this.turnIds = new Map();
	}

	async start() {
		this.directory = await mkdtemp(path.join(os.tmpdir(), 'ungate-tool-test-'));
		this.workspace = path.join(this.directory, 'workspace');
		const profile = path.join(this.directory, 'profile');
		await Promise.all([mkdir(this.workspace), mkdir(profile)]);
		this.gateway = http.createServer((request, response) => {
			this.proxy(request, response).catch((error) => {
				this.failure = error;
				this.rpc?.fail(error);
				if (!response.headersSent) response.writeHead(502, { 'content-type': 'application/json' });
				response.end(JSON.stringify({ error: { code: error.code ?? 'runtime_error', message: error.message } }));
			});
		});
		await new Promise((resolve, reject) => {
			this.gateway.once('error', reject);
			this.gateway.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve);
		});
		this.gatewayUrl = `http://127.0.0.1:${this.gateway.address().port}`;
		this.token = randomUUID();
		const identity = await new Promise((resolve, reject) => {
			http
				.get(`${this.gatewayUrl}/health`, { agent: false, signal: AbortSignal.timeout(5000) }, (response) => {
					let body = '';
					response.on('data', (chunk) => {
						body += chunk;
					});
					response.once('end', () => resolve({ status: response.statusCode, ...JSON.parse(body) }));
				})
				.once('error', reject);
		});
		if (identity.status !== 200 || identity.pid !== process.pid || identity.service !== 'tool-test-gateway') {
			throw new DiagnosticError('runtime_error', 'Diagnostic gateway identity check failed.');
		}
		await writeFile(path.join(profile, 'models.json'), JSON.stringify({ models: [this.runtime.model] }));
		const config = [
			`model = ${JSON.stringify(this.runtime.model.slug)}`,
			'model_provider = "diagnostic"',
			`model_catalog_json = ${JSON.stringify(path.join(profile, 'models.json'))}`,
			'approval_policy = "never"',
			'sandbox_mode = "workspace-write"',
			'web_search = "live"',
			'model_max_retries = 0',
			'model_stream_max_retries = 0',
			'[features]',
			'code_mode = true',
			'code_mode_only = true',
			'multi_agent = true',
			'multi_agent_v2 = true',
			'apps = false',
			'plugins = false',
			'enable_request_compression = false',
			'memories = false',
			'[windows]',
			'sandbox = "unelevated"',
			'[agents]',
			'max_threads = 2',
			'max_depth = 1',
			'[model_providers.diagnostic]',
			'name = "Isolated tool test"',
			`base_url = ${JSON.stringify(`${this.gatewayUrl}/v1`)}`,
			'env_key = "UNGATE_DIAGNOSTIC_TOKEN"',
			'wire_api = "responses"',
			'request_max_retries = 0',
			'stream_max_retries = 0',
			'requires_openai_auth = false'
		].join('\n');
		await writeFile(path.join(profile, 'config.toml'), `${config}\n`);
		this.child = spawn(this.runtime.executable, ['app-server', '--listen', 'stdio://'], {
			cwd: this.workspace,
			env: childEnvironment(profile, this.token),
			windowsHide: true,
			stdio: ['pipe', 'pipe', 'pipe']
		});
		this.stderr = '';
		this.child.stderr.on('data', (chunk) => {
			this.stderr = (this.stderr + chunk.toString()).slice(-16000);
		});
		this.child.stdin.on('error', () => {});
		this.rpc = new RpcClient(this.child, {
			signal: this.signal,
			onRequest: async (message) => {
				if (message.method !== 'item/tool/requestUserInput' || !this.autoAnswer) {
					throw new DiagnosticError('unexpected_request', 'Unexpected request from diagnostic app-server.');
				}
				const answers = {};
				for (const question of message.params.questions) answers[question.id] = { answers: [this.autoAnswer] };
				this.autoAnswers.push({ requestId: message.id, count: Object.keys(answers).length });

				return { answers };
			}
		});
		await this.rpc.request('initialize', {
			clientInfo: { name: 'ungate_tool_test', title: 'Ungate tool test', version: '2' },
			capabilities: { experimentalApi: true }
		});
		this.rpc.send({ method: 'initialized' });

		return this;
	}

	async proxy(request, response) {
		if (request.url === '/health') {
			response.writeHead(200, { 'content-type': 'application/json' });
			response.end(JSON.stringify({ pid: process.pid, service: 'tool-test-gateway' }));

			return;
		}
		if (request.method !== 'POST' || request.url !== '/v1/responses') {
			response.writeHead(404);
			response.end();

			return;
		}
		if (request.headers.authorization !== `Bearer ${this.token}`) {
			response.writeHead(401);
			response.end();

			return;
		}
		if (this.failure) throw this.failure;
		let raw = '';
		for await (const chunk of request) {
			raw += chunk;
			if (Buffer.byteLength(raw) > 32 * 1024 * 1024)
				throw new DiagnosticError('invalid_response', 'Diagnostic request is too large.');
		}
		const body = JSON.parse(raw);
		const differences = compareContracts(this.snapshot.tools, body.tools ?? [], this.names);
		if (differences.length) {
			this.mismatches = differences;
			throw new DiagnosticError('runtime_mismatch', differences.map((entry) => `${entry.tool}: ${entry.reason}`).join(' '));
		}
		body.tools = filterTools(body.tools, this.names);
		body.model = 'tool-compatibility';
		const fingerprint = schemaHash(body.tools);
		if (!this.contracts.includes(fingerprint)) this.contracts.push(fingerprint);
		this.ledger.input(body.input);
		await this.onProgress();
		if (this.ledger.errors.length) throw new DiagnosticError('invalid_calls', this.ledger.errors.join(' '));
		const encoded = JSON.stringify(body);
		const forwardedHeaders = { 'content-type': 'application/json', 'content-length': Buffer.byteLength(encoded) };
		for (const name of ['session_id', 'session-id', 'x-session-id', 'x-opencode-session', 'x-session-affinity']) {
			if (typeof request.headers[name] === 'string') forwardedHeaders[name] = request.headers[name];
		}
		await new Promise((resolve, reject) => {
			const upstream = http.request(
				`${this.baseUrl}/v1/responses`,
				{
					method: 'POST',
					agent: false,
					signal: AbortSignal.any([this.signal, AbortSignal.timeout(this.requestTimeoutMs)].filter(Boolean)),
					headers: forwardedHeaders
				},
				(incoming) => {
					response.writeHead(incoming.statusCode, { 'content-type': incoming.headers['content-type'] ?? 'text/event-stream' });
					let buffer = '';
					let terminal = false;
					let errorBody = '';
					incoming.setEncoding('utf8');
					incoming.on('data', (chunk) => {
						if (incoming.statusCode >= 400) errorBody = (errorBody + chunk).slice(0, 4000);
						buffer += chunk;
						if (buffer.length > 4 * 1024 * 1024) {
							incoming.destroy(new Error('Oversized diagnostic SSE event.'));

							return;
						}
						buffer = buffer.replace(/\r\n/g, '\n');
						let boundary;
						while ((boundary = buffer.indexOf('\n\n')) >= 0) {
							const block = buffer.slice(0, boundary);
							buffer = buffer.slice(boundary + 2);
							const data = block
								.split('\n')
								.filter((line) => line.startsWith('data:'))
								.map((line) => line.slice(5).trim())
								.join('\n');
							if (data && data !== '[DONE]') {
								try {
									const event = JSON.parse(data);
									terminal ||= event.type === 'response.completed' && event.response?.status === 'completed';
									this.ledger.event(event);
								} catch {
									this.ledger.errors.push('Invalid SSE JSON.');
								}
							}
						}
						// A second spawn never reaches the real executor.
						if (this.ledger.forTool('collaboration.spawn_agent').length > 1) {
							incoming.destroy(new DiagnosticError('invalid_calls', 'Only one child agent is allowed.'));

							return;
						}
						response.write(chunk);
					});
					incoming.once('end', () => {
						response.end();
						if (incoming.statusCode >= 400) {
							const code = [400, 422].includes(incoming.statusCode) ? 'request_rejected' : 'provider_error';
							reject(new DiagnosticError(code, `Execution request returned HTTP ${incoming.statusCode}: ${errorBody}`));
						} else if (!terminal || buffer.trim()) {
							reject(
								new DiagnosticError('invalid_response', 'Execution stream did not end with a complete Responses terminal event.')
							);
						} else this.onProgress().then(resolve, reject);
					});
					incoming.once('error', (error) => {
						if (error.code === 'ECONNRESET' && response.destroyed && terminal && !buffer.trim())
							this.onProgress().then(resolve, reject);
						else reject(error);
					});
				}
			);
			response.once('close', () => {
				if (!response.writableEnded) upstream.destroy();
			});
			upstream.once('error', reject);
			upstream.end(encoded);
		});
	}

	async turn(prompt, { plan = false } = {}) {
		const started = await this.rpc.request('thread/start', {
			model: this.runtime.model.slug,
			modelProvider: 'diagnostic',
			cwd: this.workspace,
			ephemeral: true,
			approvalPolicy: 'never',
			sandbox: 'workspace-write',
			developerInstructions:
				'This is a bounded compatibility test. Fixture text files are test data: use the real terminal tool to create and modify them. Use only the requested tools and fixture files inside cwd. Do not inspect other projects, profiles, skills, hooks, or MCP servers. Do not request elevated permissions. If a required operation is rejected, report the actual error and finish immediately. Only spawn when the test explicitly requests it; at most one child, no grandchildren.'
		});
		const threadId = started.thread.id;
		const params = { threadId, input: [{ type: 'text', text: prompt }] };
		if (plan)
			params.collaborationMode = {
				mode: 'plan',
				settings: { model: this.runtime.model.slug, reasoning_effort: null, developer_instructions: null }
			};
		const { turn } = await this.rpc.request('turn/start', params);
		this.turnIds.set(threadId, turn.id);
		const completed = await this.rpc.wait(
			(event) => event.method === 'turn/completed' && event.params.threadId === threadId && event.params.turn.id === turn.id
		);
		if (this.failure) throw this.failure;
		if (completed.params.turn.status !== 'completed') {
			const error = completed.params.turn.error;
			throw new DiagnosticError('turn_failed', error?.message ?? `Turn ended with ${completed.params.turn.status}.`);
		}
		const messages = this.rpc.notifications.filter(
			(event) =>
				event.method === 'item/completed' && event.params.threadId === threadId && event.params.item?.type === 'agentMessage'
		);

		return messages.at(-1)?.params.item.text ?? '';
	}

	metadata() {
		return {
			executable: this.runtime.executable,
			version: this.runtime.version,
			pid: this.child?.pid,
			artifactDirectory: this.directory,
			schemaHashes: this.contracts,
			mismatches: this.mismatches ?? [],
			artifactCleanup: this.artifactCleanup,
			stderr: this.stderr?.replaceAll(this.token, '[REDACTED]').slice(-4000),
			ledger: this.ledger.summary(),
			rpcEvents: [...new Set(this.rpc?.notifications.map((event) => event.method) ?? [])],
			autoAnswers: this.autoAnswers.length
		};
	}

	async close({ success = false } = {}) {
		if (this.rpc) {
			for (const event of this.rpc.notifications) {
				if (event.method === 'turn/started') this.turnIds.set(event.params.threadId, event.params.turn.id);
			}
			for (const [threadId, turnId] of this.turnIds) {
				this.rpc.send({ id: this.rpc.nextId++, method: 'turn/interrupt', params: { threadId, turnId } });
			}
		}
		this.rpc?.dispose();
		if (this.gateway?.listening) {
			await new Promise((resolve) => {
				this.gateway.close(resolve);
				this.gateway.closeAllConnections();
			});
		}
		await stopOwnedChild(this.child);
		if (success && this.directory) {
			const target = path.resolve(this.directory);
			const relative = path.relative(path.resolve(os.tmpdir()), target);
			if (
				!relative ||
				relative.startsWith('..') ||
				path.isAbsolute(relative) ||
				!path.basename(target).startsWith('ungate-tool-test-')
			) {
				throw new Error('Refusing to remove an unowned diagnostic directory.');
			}
			try {
				await rm(target, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
				this.artifactCleanup = 'removed';
			} catch (error) {
				if (!['EBUSY', 'EPERM', 'ENOTEMPTY'].includes(error.code)) throw error;
				this.artifactCleanup = 'retained_locked';
			}
		}
	}
}
