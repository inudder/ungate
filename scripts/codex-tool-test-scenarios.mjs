import { randomUUID } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { TOOL_PURPOSES } from './codex-tool-test-contract.mjs';
import { CodexTestRuntime, inspectRuntime } from './codex-tool-test-runtime.mjs';

const COLLABORATION = Object.keys(TOOL_PURPOSES).filter((name) => name.startsWith('collaboration.'));

export const SCENARIOS = [
	{ id: 'exec-files', tools: ['exec'], dependencies: ['exec'] },
	{ id: 'exec-wait', tools: ['wait'], dependencies: ['exec', 'wait'] },
	{ id: 'question', tools: ['request_user_input'], dependencies: ['request_user_input'], plan: true },
	{ id: 'collaboration', tools: COLLABORATION, dependencies: ['exec', 'wait', ...COLLABORATION] },
	{ id: 'web-search', tools: ['web_search'], dependencies: ['web_search'] },
	{ id: 'combined', tools: [], dependencies: ['exec', 'wait'], fullSet: true }
];

function stages(status, reason) {
	return { call: status, execution: status, continuation: status, ...(reason ? { reason } : {}) };
}

export function initialToolResults(checks) {
	return checks.map(({ name }) => ({
		tool: name,
		purpose: TOOL_PURPOSES[name] ?? 'сценарий выполнения ещё не определён',
		schema: 'not_tested',
		...stages('not_tested', 'Execution has not been tested.')
	}));
}

function failedOutput(output) {
	return /(?:^|\n)(?:Script (?:failed|error)|Error(?:\s*\[[^\]]+\])?:|Tool (?:error|execution failed)|error:)|"(?:isError|is_error)"\s*:\s*true|"exit_code"\s*:\s*[1-9]/i.test(
		output ?? ''
	);
}

export function evaluateCalls(runtime, names) {
	const results = {};
	for (const name of names) {
		const calls = runtime.ledger.forTool(name);
		if (!calls.length || runtime.ledger.errors.length) {
			results[name] = stages('failed', runtime.ledger.errors.join(' ') || 'The model did not call this tool.');
			continue;
		}
		const successful = calls.every((call) =>
			name === 'web_search' ? call.item.status === 'completed' : call.output !== undefined && !failedOutput(call.output)
		);
		results[name] = {
			call: 'passed',
			execution: successful ? 'passed' : 'failed',
			continuation: 'not_tested',
			...(successful ? {} : { reason: 'Executor result is missing or reports an error.' })
		};
	}

	return results;
}

async function prepareScenario(runtime, scenario) {
	const nonce = randomUUID();
	const fixture = path.join(runtime.workspace, 'fixture.txt');
	const target = path.join(runtime.workspace, 'result.txt');
	const second = path.join(runtime.workspace, 'second.txt');
	const other = randomUUID();
	await Promise.all([writeFile(fixture, nonce), writeFile(second, other)]);
	const paths = `The fixture file is ${JSON.stringify(fixture)}. The result file is ${JSON.stringify(target)}. `;
	const bounded =
		'Use real tools, never fabricate results. Use only files in cwd. Commands must be finite and run without a PowerShell profile. Do not spawn agents unless explicitly requested. ';
	const prompts = {
		'exec-files': `${bounded}${paths}Call exec to use a real nested terminal tool to read the fixture, write exactly its contents to the result file, then read the result back. In your final answer return only the contents you actually read.`,
		'exec-wait': `${bounded}${paths}Call exec with a first-line pragma // @exec: {"yield_time_ms": 1}. Inside that cell await a finite delay of 1500 milliseconds, then use a real nested terminal tool to read the fixture and print its contents with text(). The cell must yield. Use the separate wait tool with the returned cell_id until it completes. Return only the actual fixture contents in your final answer. Do not call tools.wait inside exec.`,
		question:
			'Compatibility test: use request_user_input exactly once to ask which test value to use, with question id compatibility_value and two options. The automated client will supply its own free-text value. After receiving the answer, return only the value from the tool result. No other tool is needed.',
		collaboration: `${bounded}${paths}Test all six collaboration tools using exactly ONE child agent, no grandchildren.\n1. spawn_agent with a small task to wait for a parent message, then return exactly its contents. Do not include fixture contents in the initial task and do not let the child read files.\n2. list_agents to confirm the child exists and see its state.\n3. Read the fixture using exec, and send its actual contents to the child using collaboration.send_message.\n4. collaboration.wait_agent until you receive the child's reply containing that value.\n5. Use collaboration.followup_task on the now idle child. Ask it to run a finite 20-second delay using exec, then return DELAY_FINISHED.\n6. list_agents to confirm it is working, then call collaboration.interrupt_agent while it is working. Do not wait for DELAY_FINISHED.\nFinally, return only the fixture value you received from the child's reply.`,
		'web-search':
			'Use web_search to search for the official IANA page explaining example domains. Inspect real search results. In the final answer include a URL from those results as a clickable source. Do not answer from memory and do not use another search tool.',
		combined: `${bounded}${paths}The second fixture is ${JSON.stringify(second)}. In exec use Promise.all to read both fixtures using two actual nested terminal calls. Then run a second exec cell with // @exec: {"yield_time_ms": 1} and a finite 1500ms delay that writes the two previously read values joined by |, with no spaces, to the result file. Use the separate wait tool after this cell yields. Read the result using a real tool and return only its contents. Do not call tools.wait inside exec.`
	};

	return { prompt: prompts[scenario.id], nonce, target, expected: scenario.id === 'combined' ? `${nonce}|${other}` : nonce };
}

function verifyWait(runtime) {
	const waits = runtime.ledger.forTool('wait');

	return waits.some((call) => {
		const args = JSON.parse(call.item.arguments);

		return (
			typeof args.cell_id === 'string' &&
			runtime.ledger
				.forTool('exec')
				.some((exec) => exec.output?.includes('Script running with cell ID') && exec.output.includes(args.cell_id))
		);
	});
}

function verifyCollaboration(runtime, nonce) {
	const ledger = runtime.ledger;
	const spawn = ledger.forTool('collaboration.spawn_agent');
	if (spawn.length !== 1 || spawn[0].item.arguments.includes(nonce)) return false;
	const delivered = ledger
		.forTool('collaboration.send_message')
		.find((call) => JSON.parse(call.item.arguments).message?.includes(nonce));
	if (!delivered) return false;
	const target = JSON.parse(delivered.item.arguments).target;
	if (!target || !spawn[0].output?.includes(target)) return false;
	const sameAgent = (call) => JSON.parse(call.item.arguments).target === target;
	const listed = ledger
		.forTool('collaboration.list_agents')
		.find((call) => call.sequence > spawn[0].sequence && call.sequence < delivered.sequence && call.output?.includes(target));
	const waited = ledger.forTool('collaboration.wait_agent').find((call) => call.sequence > delivered.sequence);
	const reply =
		waited &&
		(waited.output?.includes(nonce) || ledger.contextMessages.some((text) => text.includes(nonce) && text.includes(target)));
	const followup = ledger
		.forTool('collaboration.followup_task')
		.find((call) => sameAgent(call) && call.sequence > waited?.sequence);
	const interrupted = ledger
		.forTool('collaboration.interrupt_agent')
		.find((call) => sameAgent(call) && call.sequence > followup?.sequence);
	const activeState =
		interrupted &&
		ledger
			.forTool('collaboration.list_agents')
			.some(
				(call) =>
					call.sequence > followup.sequence &&
					call.sequence < interrupted.sequence &&
					call.output?.includes(target) &&
					/running|working|active/i.test(call.output)
			);

	return Boolean(listed && reply && followup && activeState && /running|working|active/i.test(interrupted.output ?? ''));
}

export async function verifyScenario(runtime, scenario, fixture, finalText) {
	if (scenario.id === 'web-search') {
		const urls = runtime.ledger.messages.flatMap((message) =>
			(message.content ?? []).flatMap((content) =>
				(content.annotations ?? []).filter((annotation) => annotation.type === 'url_citation').map((annotation) => annotation.url)
			)
		);

		return urls.some((url) => /^https?:\/\//.test(url) && finalText.includes(url));
	}
	if (!finalText.includes(fixture.expected)) return false;
	if (['exec-files', 'combined'].includes(scenario.id)) {
		const actual = await readFile(fixture.target, 'utf8').catch(() => null);
		if (actual !== fixture.expected) return false;
	}
	if (['exec-wait', 'combined'].includes(scenario.id) && !verifyWait(runtime)) return false;
	if (scenario.id === 'question' && runtime.autoAnswers.length !== 1) return false;
	if (scenario.id === 'collaboration' && !verifyCollaboration(runtime, fixture.nonce)) return false;
	if (scenario.id === 'combined') {
		const parallelCode = runtime.ledger.forTool('exec').some((call) => /Promise\.all\s*\(/.test(call.item.input));
		if (!parallelCode) return false;
	}

	return true;
}

export async function runFunctionalChecks({
	configuration,
	modelReport,
	snapshot,
	baseUrl,
	signal,
	timeoutMs = 180000,
	requestTimeoutMs = 120000,
	save = async () => {},
	log = () => {},
	runtimeFactory = (options) => new CodexTestRuntime(options),
	runtimeInspector = inspectRuntime
}) {
	const rows = modelReport.toolResults;
	const schema = new Map(modelReport.checks.map((check) => [check.tool, check.status]));
	for (const row of rows) row.schema = schema.get(row.tool) ?? 'not_tested';
	modelReport.executionChecks = [];
	let runtimeInfo;
	try {
		runtimeInfo = await runtimeInspector(configuration);
	} catch (error) {
		modelReport.runtime = { status: 'runtime_unavailable', reason: error.message };
		for (const row of rows) Object.assign(row, stages('not_tested', error.message));
		await save();

		return;
	}
	modelReport.runtime = { executable: runtimeInfo.executable, version: runtimeInfo.version };
	const available = new Set(rows.map((row) => row.tool));
	for (const scenario of SCENARIOS) {
		const check = { scenario: scenario.id, tools: scenario.tools, dependencies: scenario.dependencies, status: 'not_tested' };
		modelReport.executionChecks.push(check);
		const dependencies = scenario.fullSet ? [...available] : scenario.dependencies;
		const blocked = dependencies.filter((name) => schema.get(name) !== 'accepted');
		if (blocked.length || (scenario.fullSet && schema.get('(весь набор)') !== 'accepted')) {
			const gates = blocked.length ? blocked : ['(весь набор)'];
			check.blockedBy = gates.map((tool) => ({ tool, status: schema.get(tool) ?? 'missing' }));
			check.status = check.blockedBy.every((gate) => gate.status === 'schema_rejected') ? 'blocked' : 'coverage_missing';
			check.reason = `Schema gate did not pass: ${blocked.join(', ') || '(весь набор)'}.`;
			for (const row of rows.filter((row) => scenario.tools.includes(row.tool)))
				Object.assign(row, stages('blocked', check.reason));
			await save();
			continue;
		}
		if (signal?.aborted) {
			check.status = 'cancelled';
			await save();
			break;
		}
		const timeout = AbortSignal.timeout(timeoutMs);
		const scenarioSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
		const autoAnswer = scenario.id === 'question' ? randomUUID() : undefined;
		const runtime = runtimeFactory({
			runtime: runtimeInfo,
			baseUrl,
			snapshot,
			names: dependencies,
			signal: scenarioSignal,
			requestTimeoutMs,
			autoAnswer,
			onProgress: async () => {
				check.runtime = runtime.metadata();
				check.results = evaluateCalls(runtime, scenario.tools.length ? scenario.tools : scenario.dependencies);
				await save();
			}
		});
		const started = Date.now();
		check.status = 'running';
		log(`Выполнение: ${scenario.id}`);
		await save();
		try {
			await runtime.start();
			const fixture = await prepareScenario(runtime, scenario);
			if (autoAnswer) fixture.expected = autoAnswer;
			const finalText = await runtime.turn(fixture.prompt, { plan: scenario.plan });
			const toolResults = evaluateCalls(runtime, scenario.tools.length ? scenario.tools : scenario.dependencies);
			const continued = await verifyScenario(runtime, scenario, fixture, finalText);
			for (const result of Object.values(toolResults)) {
				result.continuation = continued && result.execution === 'passed' ? 'passed' : 'failed';
				if (!continued) result.reason ??= 'Scenario postcondition or use of the actual tool result was not confirmed.';
			}
			check.status = Object.values(toolResults).every((result) =>
				[result.call, result.execution, result.continuation].every((stage) => stage === 'passed')
			)
				? 'passed'
				: 'failed';
			check.results = toolResults;
			for (const row of rows.filter((row) => scenario.tools.includes(row.tool))) {
				delete row.reason;
				Object.assign(row, toolResults[row.tool]);
			}
		} catch (error) {
			if (signal?.aborted) check.status = 'cancelled';
			else if (timeout.aborted) check.status = 'timeout';
			else if (['invalid_calls', 'request_rejected'].includes(error.code)) check.status = 'failed';
			else check.status = error.code ?? 'runtime_error';
			check.reason = error.message;
			check.results = evaluateCalls(runtime, scenario.tools.length ? scenario.tools : scenario.dependencies);
			for (const row of rows.filter((row) => scenario.tools.includes(row.tool))) {
				const observed = runtime.ledger.forTool(row.tool).length ? check.results[row.tool] : stages('not_tested');
				Object.assign(row, observed, { reason: check.reason });
			}
		} finally {
			check.durationMs = Date.now() - started;
			check.runtime = runtime.metadata();
			await save();
			try {
				await runtime.close({ success: check.status === 'passed' });
				check.cleanup = 'passed';
			} catch (error) {
				check.status = 'cleanup_failed';
				check.reason = error.message;
				throw error;
			} finally {
				check.runtime = runtime.metadata();
				await save();
			}
		}
		log(`${scenario.id}: ${check.status}${check.reason ? ` — ${check.reason}` : ''}`);
	}
	for (const row of rows) {
		if (!TOOL_PURPOSES[row.tool]) row.reason = 'No execution scenario is registered for this tool.';
	}
	await save();
}
