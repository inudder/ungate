import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { EventEmitter, once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';

import { classifyError, individualTools, reportExitCode } from './codex-tool-compatibility.mjs';
import { compareContracts, filterTools, TOOL_PURPOSES, ToolLedger } from './codex-tool-test-contract.mjs';
import { CodexTestRuntime, DiagnosticError, RpcClient, stopOwnedChild } from './codex-tool-test-runtime.mjs';
import { evaluateCalls, initialToolResults, runFunctionalChecks } from './codex-tool-test-scenarios.mjs';

const definitions = [
	{ type: 'custom', name: 'exec', format: { type: 'text' } },
	{ type: 'function', name: 'wait', parameters: { type: 'object' } },
	{ type: 'function', name: 'request_user_input', parameters: { type: 'object' } },
	{
		type: 'namespace',
		name: 'collaboration',
		tools: Object.keys(TOOL_PURPOSES)
			.filter((name) => name.startsWith('collaboration.'))
			.map((name) => ({
				type: 'function',
				name: name.split('.')[1],
				parameters: { type: 'object' }
			}))
	},
	{ type: 'web_search' }
];

test('diagnostic gateway preserves the Codex session and accepts disconnect only after completed', async () => {
	for (const completed of [true, false]) {
		let session;
		const upstream = http.createServer(async (request, response) => {
			session = request.headers.session_id;
			for await (const chunk of request) void chunk;
			response.writeHead(200, { 'content-type': 'text/event-stream' });
			response.write(
				completed
					? 'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'
					: 'data: {"type":"response.created"}\n\n'
			);
		});
		await new Promise((resolve) => upstream.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve));
		const runtime = new CodexTestRuntime({
			baseUrl: `http://127.0.0.1:${upstream.address().port}`,
			snapshot: { tools: [] },
			names: []
		});
		runtime.token = 'fixture';
		let finish;
		const outcome = new Promise((resolve) => {
			finish = resolve;
		});
		const gateway = http.createServer((request, response) => {
			runtime.proxy(request, response).then(() => finish(null), finish);
		});
		await new Promise((resolve) => gateway.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve));
		try {
			const request = http.request(
				`http://127.0.0.1:${gateway.address().port}/v1/responses`,
				{ method: 'POST', headers: { authorization: 'Bearer fixture', session_id: 'fixture-chat' } },
				(response) => {
					response.once('data', () => response.destroy());
				}
			);
			request.end('{"tools":[],"input":[]}');
			const error = await outcome;
			assert.equal(session, 'fixture-chat');
			if (completed) assert.equal(error, null);
			else assert.ok(error);
		} finally {
			gateway.closeAllConnections();
			upstream.closeAllConnections();
			await Promise.all([new Promise((resolve) => gateway.close(resolve)), new Promise((resolve) => upstream.close(resolve))]);
		}
	}
});

function call(ledger, name, { input = 'text(1)', args = {}, output = 'ok', id = `${name}-${ledger.calls.size}` } = {}) {
	let item;
	if (name === 'exec') item = { type: 'custom_tool_call', id, call_id: id, name, input };
	else {
		const parts = name.split('.');
		item = { type: 'function_call', id, call_id: id, name: parts.at(-1), arguments: JSON.stringify(args) };
		if (parts.length > 1) item.namespace = parts[0];
	}
	ledger.event({ type: 'response.output_item.done', item });
	ledger.input([{ type: 'function_call_output', call_id: id, output }]);

	return item;
}

// Deliberately synthetic executor, available only through dependency injection in offline tests.
function syntheticRuntime(t, behavior = {}) {
	return (options) => ({
		...options,
		ledger: new ToolLedger(options.names),
		autoAnswers: [],
		async start() {
			this.workspace = await mkdtemp(path.join(os.tmpdir(), 'ungate-tools-unit-'));
			t.after(() => rm(this.workspace, { recursive: true, force: true }));

			return this;
		},
		async turn(prompt) {
			if (behavior.error) throw new DiagnosticError(behavior.error, 'Synthetic runtime failure.');
			if (this.signal.aborted) throw new DiagnosticError('cancelled', 'Synthetic cancellation.');
			const nonce = await readFile(path.join(this.workspace, 'fixture.txt'), 'utf8');
			let result = nonce;
			if (prompt.includes('compatibility_value')) {
				call(this.ledger, 'request_user_input', { output: this.autoAnswer });
				this.autoAnswers.push({ requestId: 1 });
				result = this.autoAnswer;
			} else if (prompt.includes('IANA')) {
				const url = 'https://www.iana.org/help/example-domains';
				this.ledger.item({ type: 'web_search_call', id: 'search-1', status: 'completed' }, true);
				this.ledger.messages.push({ content: [{ annotations: [{ type: 'url_citation', url }] }] });
				result = url;
			} else if (prompt.includes('ONE child')) {
				call(this.ledger, 'collaboration.spawn_agent', { args: { message: 'Wait for parent.' }, output: 'child-one' });
				call(this.ledger, 'collaboration.list_agents', { output: 'child-one: working' });
				call(this.ledger, 'collaboration.send_message', { args: { target: 'child-one', message: nonce } });
				call(this.ledger, 'collaboration.wait_agent', { output: nonce });
				call(this.ledger, 'collaboration.followup_task', { args: { target: 'child-one' }, output: 'working' });
				call(this.ledger, 'collaboration.list_agents', { output: 'child-one: working' });
				call(this.ledger, 'collaboration.interrupt_agent', { args: { target: 'child-one' }, output: 'previous status: working' });
			} else {
				if (prompt.includes('Promise.all')) {
					const second = await readFile(path.join(this.workspace, 'second.txt'), 'utf8');
					result = `${nonce}|${second}`;
					call(this.ledger, 'exec', { input: 'await Promise.all([]);', output: 'ok' });
				}
				if (prompt.includes('cell_id') || prompt.includes('Promise.all')) {
					call(this.ledger, 'exec', { output: 'Script running with cell ID unit-cell' });
					call(this.ledger, 'wait', { args: { cell_id: 'unit-cell' }, output: result });
				} else call(this.ledger, 'exec', { output: behavior.executionError ? 'Error: interpreter failed' : result });
				await writeFile(path.join(this.workspace, 'result.txt'), result);
			}
			if (behavior.invalidIds) this.ledger.errors.push('Conflicting tool call IDs.');

			return behavior.wrongFinal ? 'fabricated success' : result;
		},
		metadata() {
			return { version: 'unit-fixture', ledger: this.ledger.summary() };
		},
		async close() {
			behavior.closed = (behavior.closed ?? 0) + 1;
		}
	});
}

async function run(t, { behavior = {}, rejected = [], fullSetRejected = false, tools = definitions, signal } = {}) {
	const entries = individualTools(tools);
	const modelReport = {
		checks: [
			{ tool: '(контроль без инструментов)', status: 'accepted' },
			...entries.map(({ name }) => ({ tool: name, status: rejected.includes(name) ? 'schema_rejected' : 'accepted' })),
			{ tool: '(весь набор)', status: fullSetRejected ? 'schema_rejected' : 'accepted' }
		],
		toolResults: initialToolResults(entries)
	};
	const saves = [];
	await runFunctionalChecks({
		configuration: {},
		snapshot: { tools },
		modelReport,
		signal,
		runtimeInspector: async () => ({ executable: 'offline-fixture', version: 'unit-fixture' }),
		runtimeFactory: syntheticRuntime(t, behavior),
		save: async () => saves.push(structuredClone(modelReport))
	});

	return { modelReport, saves, exitCode: reportExitCode({ version: 2, models: [modelReport] }) };
}

test('contract comparison preserves every input constraint and namespace while ignoring prose', () => {
	const actual = structuredClone(definitions);
	actual[1].description = 'Different wording.';
	assert.deepEqual(compareContracts(definitions, actual, new Set(['wait'])), []);
	actual[1].parameters.required = ['cell_id'];
	assert.equal(compareContracts(definitions, actual, new Set(['wait']))[0].tool, 'wait');
	assert.equal(compareContracts(definitions, [], new Set(['exec']))[0].tool, 'exec');
	const strict = structuredClone(definitions);
	strict[1].strict = true;
	assert.equal(compareContracts(definitions, strict, new Set(['wait']))[0].tool, 'wait');
	const selected = filterTools(definitions, new Set(['collaboration.send_message']));
	assert.equal(selected[0].name, 'collaboration');
	assert.deepEqual(
		selected[0].tools.map((tool) => tool.name),
		['send_message']
	);
});

test('ledger permits terminal replay but rejects duplicate streams, missing and conflicting IDs or outputs', () => {
	const ledger = new ToolLedger(['exec']);
	const item = call(ledger, 'exec');
	ledger.event({ type: 'response.completed', response: { output: [item] } });
	assert.deepEqual(ledger.errors, []);
	ledger.event({ type: 'response.output_item.done', item });
	ledger.item({ ...item, input: 'different' }, false);
	ledger.input([{ type: 'custom_tool_call_output', call_id: item.call_id, output: 'conflicting' }]);
	ledger.input([{ type: 'custom_tool_call_output', call_id: 'unknown', output: 'ok' }]);
	ledger.item({ ...item, call_id: null }, false);
	assert.ok(ledger.errors.some((error) => error.includes('Duplicate')));
	assert.ok(ledger.errors.some((error) => error.includes('Conflicting tool call')));
	assert.ok(ledger.errors.some((error) => error.includes('Conflicting tool outputs')));
	assert.ok(ledger.errors.some((error) => error.includes('matching call')));
	assert.ok(ledger.errors.some((error) => error.includes('missing identity')));
});

test('successful calls and HTTP completion do not conceal executor failure', () => {
	const ledger = new ToolLedger(['exec']);
	call(ledger, 'exec', { output: 'Error: the real executor failed' });
	const result = evaluateCalls({ ledger }, ['exec']).exec;
	assert.equal(result.call, 'passed');
	assert.equal(result.execution, 'failed');
	assert.equal(result.continuation, 'not_tested');
});

test('all ten tools require their actual calls, results and verified continuation', async (t) => {
	const behavior = {};
	const result = await run(t, { behavior });
	assert.equal(result.exitCode, 0);
	assert.equal(result.modelReport.toolResults.length, 10);
	assert.equal(result.modelReport.executionChecks.length, 6);
	assert.ok(result.modelReport.toolResults.every((row) => row.execution === 'passed' && row.continuation === 'passed'));
	assert.equal(behavior.closed, 6);
	assert.ok(result.saves.some((saved) => saved.executionChecks.some((check) => check.status === 'running')));
});

test('individual schema failure blocks execution and dependencies, but full-set failure still permits isolated tools', async (t) => {
	const rejected = await run(t, { rejected: ['exec'] });
	assert.equal(rejected.exitCode, 1);
	assert.equal(rejected.modelReport.toolResults.find((row) => row.tool === 'exec').execution, 'blocked');
	assert.equal(rejected.modelReport.toolResults.find((row) => row.tool === 'wait').execution, 'blocked');
	assert.equal(rejected.modelReport.toolResults.find((row) => row.tool === 'web_search').execution, 'passed');
	const full = await run(t, { fullSetRejected: true });
	assert.equal(full.exitCode, 1);
	assert.ok(full.modelReport.toolResults.every((row) => row.execution === 'passed'));
	assert.equal(full.modelReport.executionChecks.at(-1).status, 'blocked');
	assert.equal(
		classifyError(400, { param: 'tool_choice', message: 'tools require a supported tool_choice' }).status,
		'provider_error'
	);
});

test('runtime mismatch, unimplemented tools and cancellation stay incomplete; failed continuation is a real failure', async (t) => {
	const mismatch = await run(t, { behavior: { error: 'runtime_mismatch' } });
	assert.equal(mismatch.exitCode, 2);
	assert.ok(mismatch.modelReport.toolResults.every((row) => row.execution === 'not_tested'));
	const unknown = await run(t, { tools: [...definitions, { type: 'function', name: 'new_tool', parameters: {} }] });
	assert.equal(unknown.exitCode, 2);
	assert.match(unknown.modelReport.toolResults.at(-1).reason, /No execution scenario/);
	const absent = await run(t, { tools: definitions.filter((tool) => tool.name !== 'wait') });
	assert.equal(absent.exitCode, 2);
	assert.equal(absent.modelReport.executionChecks.find((check) => check.scenario === 'exec-wait').status, 'coverage_missing');
	const cancelled = await run(t, { signal: AbortSignal.abort() });
	assert.equal(cancelled.exitCode, 2);
	assert.equal(cancelled.modelReport.executionChecks[0].status, 'cancelled');
	const wrong = await run(t, { behavior: { wrongFinal: true } });
	assert.equal(wrong.exitCode, 1);
	assert.equal(wrong.modelReport.toolResults[0].execution, 'passed');
	assert.equal(wrong.modelReport.toolResults[0].continuation, 'failed');
});

test('RPC auto-answer, notification ordering and cancellation use real stdio frames without pending listeners', async () => {
	const child = new EventEmitter();
	child.stdout = new PassThrough();
	child.stdin = new PassThrough();
	const frames = [];
	child.stdin.on('data', (chunk) => frames.push(JSON.parse(chunk.toString())));
	const controller = new AbortController();
	const rpc = new RpcClient(child, {
		signal: controller.signal,
		onRequest: async () => ({ answers: { q: { answers: ['fixture'] } } })
	});
	const pending = rpc.request('initialize', {});
	child.stdout.write(`${JSON.stringify({ id: frames[0].id, result: { userAgent: 'fixture' } })}\n`);
	const initialized = await pending;
	assert.equal(initialized.userAgent, 'fixture');
	child.stdout.write(`${JSON.stringify({ id: 500, method: 'item/tool/requestUserInput', params: {} })}\n`);
	await new Promise((resolve) => setImmediate(resolve));
	assert.deepEqual(frames.at(-1).result.answers.q.answers, ['fixture']);
	child.stdout.write(`${JSON.stringify({ method: 'turn/completed', params: { turnId: 'done' } })}\n`);
	const completed = await rpc.wait((message) => message.method === 'turn/completed');
	assert.equal(completed.params.turnId, 'done');
	const wait = rpc.wait((message) => message.method === 'never');
	const rejected = assert.rejects(wait, /aborted/);
	controller.abort();
	await rejected;
	assert.equal(rpc.waiters.size, 0);
	assert.equal(rpc.pending.size, 0);
	rpc.dispose();
	child.stdout.end();
	child.stdin.end();
});

test('owned native subprocesses stop on EOF and are forcibly stopped after the shutdown grace', async (t) => {
	for (const graceful of [true, false]) {
		const code = `process.stdin.resume(); ${graceful ? "process.stdin.on('end', () => process.exit(0));" : ''} setTimeout(() => process.exit(0), 30000);`;
		const child = spawn(process.execPath, ['-e', code], { windowsHide: true, stdio: ['pipe', 'ignore', 'ignore'] });
		t.after(() => {
			if (child.exitCode === null && !child.signalCode) child.kill();
		});
		await once(child, 'spawn');
		await stopOwnedChild(child);
		assert.ok(child.exitCode !== null || child.signalCode);
		assert.throws(() => process.kill(child.pid, 0));
	}
	await stopOwnedChild(undefined);
});
