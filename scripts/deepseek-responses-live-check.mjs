// Explicit live smoke test. Configuration (including credentials) arrives only on stdin.
// Generated code is never executed; tool results are synthetic test data.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { writeFile } from 'node:fs/promises';

import { createShellRouterServer } from './codex-model-shell-router.mjs';

let raw = '';
for await (const chunk of process.stdin) raw += chunk;
const config = JSON.parse(raw);
const report = { startedAt: new Date().toISOString(), models: [] };
const server = createShellRouterServer({
	routes: config.models.map((model) => ({ ...model, clientModel: model.upstreamModel }))
});
server.listen({ host: '127.0.0.1', port: 0, exclusive: true });
await once(server, 'listening');
const base = `http://127.0.0.1:${server.address().port}`;
const deadline = setTimeout(
	() => {
		server.closeAllConnections();
	},
	15 * 60 * 1000
);
async function request(model, input, tools, toolChoice) {
	const response = await fetch(`${base}/v1/responses`, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		signal: AbortSignal.timeout(120000),
		body: JSON.stringify({
			model,
			input,
			tools,
			tool_choice: toolChoice,
			stream: true,
			reasoning: { effort: 'high' },
			max_output_tokens: 8192,
			parallel_tool_calls: true
		})
	});
	assert.equal(response.status, 200, `HTTP ${response.status}`);
	const text = await response.text();
	const events = text.split(/\r?\n\r?\n/).flatMap((frame) => {
		const data = frame
			.split(/\r?\n/)
			.filter((line) => line.startsWith('data:'))
			.map((line) => line.slice(5).trim())
			.join('\n');

		return !data || data === '[DONE]' ? [] : [JSON.parse(data)];
	});
	assert.ok(!events.some((event) => event.type === 'error' || event.type === 'response.failed'), 'SSE error');
	const completed = events.find((event) => event.type === 'response.completed');
	assert.ok(completed?.response.status === 'completed', 'No completed response');

	// Codex acts on output_item.done, not just the final response.output array.
	// Validate those events too: terminal array positions may differ upstream.
	const streamed = events.filter((event) => event.type === 'response.output_item.done').map((event) => event.item);
	const calls = streamed.filter((item) => ['custom_tool_call', 'function_call'].includes(item.type));
	assert.equal(new Set(calls.map((item) => item.call_id)).size, calls.length, 'Duplicate streamed call_id');
	assert.deepEqual(
		calls.map((item) => item.call_id).sort(),
		completed.response.output
			.filter((item) => ['custom_tool_call', 'function_call'].includes(item.type))
			.map((item) => item.call_id)
			.sort(),
		'Stream and terminal calls differ'
	);

	return streamed.length ? streamed : completed.response.output;
}
try {
	const healthResponse = await fetch(`${base}/_shell-router/health`);
	const health = await healthResponse.json();
	assert.equal(health.pid, process.pid);
	for (const model of config.models) {
		const record = { model: model.upstreamModel, checks: [] };
		report.models.push(record);
		for (const kind of ['exec', 'parallel']) {
			const start = Date.now();
			try {
				const tools =
					kind === 'exec'
						? [
								{
									type: 'custom',
									name: 'exec',
									description: 'JavaScript code. For this test only output text("deepseek-smoke");',
									format: { type: 'text' }
								}
							]
						: [
								{
									type: 'function',
									name: 'probe',
									description: 'Read one numbered synthetic test value.',
									parameters: {
										type: 'object',
										properties: { index: { type: 'integer' } },
										required: ['index'],
										additionalProperties: false
									},
									strict: true
								}
							];
				const input = [
					{
						role: 'user',
						content:
							kind === 'exec'
								? 'Call exec once with text("deepseek-smoke");. After the result, reply OK.'
								: 'Call probe exactly four times in parallel in this one response, with index 0, 1, 2, 3. Include a brief commentary before these calls. After all results, reply OK.'
					}
				];
				const output = await request(model.upstreamModel, input, tools, 'auto');
				const calls = output.filter((item) => item.type === (kind === 'exec' ? 'custom_tool_call' : 'function_call'));
				assert.equal(calls.length, kind === 'exec' ? 1 : 4, 'Unexpected call count');
				assert.ok(
					output.some(
						(item) => item.type === 'reasoning' && item.content?.some((part) => part.type === 'reasoning_text' && part.text)
					),
					'Missing reasoning_text'
				);
				if (kind === 'exec') assert.equal(typeof calls[0].input, 'string');
				const results = calls.map((call) => ({
					type: `${call.type}_output`,
					call_id: call.call_id,
					output: 'Synthetic successful result: deepseek-smoke. No code was executed.'
				}));
				// Reproduce the failing session shape even when the model omits commentary.
				// Preserve real reasoning; only this explicit fixture message is synthetic.
				const history = [...output];
				if (kind === 'parallel' && !history.some((item) => item.type === 'message')) {
					history.splice(
						history.findIndex((item) => item.type === 'function_call'),
						0,
						{
							type: 'message',
							role: 'assistant',
							phase: 'commentary',
							content: [{ type: 'output_text', text: 'Checking four synthetic test values.' }]
						}
					);
				}
				const next = await request(model.upstreamModel, [...input, ...history, ...results], tools, 'none');
				assert.ok(
					next.some((item) => item.type === 'message'),
					'Missing continuation message'
				);
				record.checks.push({
					kind,
					status: 'passed',
					calls: calls.length,
					reasoningPreserved: true,
					historyTypes: [...history, ...results].map((item) => item.type),
					durationMs: Date.now() - start
				});
			} catch (error) {
				record.checks.push({ kind, status: 'failed', reason: error.message, durationMs: Date.now() - start });
				process.exitCode = 2;
			}
			console.log(JSON.stringify({ model: record.model, ...record.checks.at(-1) }));
		}
	}
} finally {
	clearTimeout(deadline);
	server.closeAllConnections();
	await new Promise((resolve) => server.close(resolve));
	await writeFile(config.reportPath, `${JSON.stringify(report, null, 2)}\n`);
}
