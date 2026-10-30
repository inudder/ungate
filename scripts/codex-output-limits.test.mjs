import assert from 'node:assert/strict';
import http from 'node:http';
import { test } from 'node:test';

import {
	assessProbe,
	cacheState,
	evaluatePolicy,
	selectEvidence,
	recommendation,
	probe,
	withBudgetRoute,
	outputFingerprint
} from './codex-output-limits.mjs';

test('PowerShell dictionary ordering does not invalidate evidence, but changed values do', () => {
	assert.equal(outputFingerprint({ model: { a: 1, b: 2 }, limit: 32 }), outputFingerprint({ limit: 32, model: { b: 2, a: 1 } }));
	assert.notEqual(outputFingerprint({ limit: 32 }), outputFingerprint({ limit: 64 }));
});

test('a scoped default fills a missing budget, preserves an explicit client cap and does not affect another model', () => {
	const rules = { default: [{ models: [{ name: 'flash', protocol: 'deepseek' }], params: { max_tokens: 393216 } }] };
	assert.equal(evaluatePolicy({ rules, provider: 'deepseek', model: 'flash' }).configured, 393216);
	for (const field of ['max_tokens', 'max_output_tokens', 'max_completion_tokens']) {
		assert.equal(evaluatePolicy({ rules, provider: 'deepseek', model: 'flash', routerBudget: { [field]: 32 } }).configured, 32);
	}
	assert.equal(evaluatePolicy({ rules, provider: 'deepseek', model: 'other' }).configured, null);
	assert.equal(evaluatePolicy({ rules, provider: 'other', model: 'flash' }).configured, null);
});

test('caps are not defaults; wildcard, conflicting accounts and override rules remain unconfirmed', () => {
	assert.equal(evaluatePolicy({ cap: 393216 }).configured, null);
	assert.equal(evaluatePolicy({ routerBudget: { max_tokens: 100 }, cap: 50 }).configured, 50);
	assert.equal(evaluatePolicy({ defaults: [{ max_tokens: 32 }, { max_tokens: 64 }] }).configured, null);
	assert.equal(
		evaluatePolicy({ model: 'x', rules: { default: [{ models: [{ name: '*' }], params: { max_tokens: 42 } }] } }).configured,
		null
	);
	assert.equal(
		evaluatePolicy({ routerBudget: { max_tokens: 64 }, model: 'x', rules: { filter: [{ models: [{ name: 'x' }] }] } }).configured,
		null
	);
});

test('evidence is scoped to exact model, transport, endpoint and expires', () => {
	const model = { transport: 'omniroute', model: 'exact', upstreamBaseUrl: 'http://127.0.0.1:1' };
	const entry = { ...model, maximum: 100, source: 'https://provider.example/docs', checkedAt: '2026-10-30T00:00:00Z' };
	const now = Date.parse('2026-10-31T00:00:00Z');
	assert.equal(selectEvidence([entry], model, now).maximum, 100);
	assert.equal(selectEvidence([entry], { ...model, model: 'replacement' }, now), null);
	assert.equal(selectEvidence([entry], { ...model, transport: 'cliproxyapi' }, now), null);
	assert.equal(selectEvidence([entry], model, now + 31 * 86400000), null);
});

test('HTTP 200, acceptance and measured length remain separate evidence', () => {
	assert.equal(assessProbe({ httpStatus: 200 }, 100), 'failed');
	const completed = { httpStatus: 200, terminal: 'completed', outputTokens: 3 };
	assert.equal(assessProbe(completed, 100), 'request-accepted-not-maximum-proof');
	assert.equal(assessProbe(completed, 100, true), 'inconclusive');
	assert.equal(assessProbe({ ...completed, outputTokens: 100 }, 100, true), 'reached-requested-budget');
	assert.equal(assessProbe({ ...completed, outputTokens: 101 }, 100), 'budget-not-respected');
	assert.equal(assessProbe({ ...completed, error: 'timeout' }, 100, true), 'failed');
});

test('changed configuration, expired or unfinished evidence cannot recommend raising the default', () => {
	const now = Date.parse('2026-10-30T12:00:00Z');
	const snapshot = { fingerprint: 'current', policy: { configured: 32 }, evidence: { maximum: 64 } };
	const report = {
		fingerprint: 'current',
		completedAt: '2026-10-30T11:00:00Z',
		checks: [{ requestedBudget: 64, verdict: 'request-accepted-not-maximum-proof' }]
	};
	assert.equal(cacheState(report, snapshot, now), 'current');
	assert.match(recommendation(snapshot, report, 'current'), /Можно повысить/);
	assert.equal(cacheState(report, { ...snapshot, fingerprint: 'changed' }, now), 'stale');
	assert.equal(cacheState(report, snapshot, now + 8 * 86400000), 'stale');
	assert.equal(cacheState({ ...report, completedAt: null }, snapshot, now), 'stale');
	assert.doesNotMatch(recommendation(snapshot, report, 'stale'), /Можно повысить/);
});

test('real router serialization supplies Argon default and preserves a client Responses budget', async () => {
	const model = { model: 'apikey-fan/gemini-4-argon', upstreamBaseUrl: 'http://127.0.0.1:1' };
	await withBudgetRoute(
		model,
		async (url, captured) => {
			await probe(url);
			await probe(url, { budget: 32 });
			assert.deepEqual(captured, [{ max_output_tokens: 32768 }, { max_output_tokens: 32 }]);
		},
		{ offline: true }
	);
});

test('SSE probes detect truncation, missing terminals, ignored caps and timeouts without storing text or credentials', async () => {
	let mode = 'incomplete';
	const upstream = http.createServer(async (request, response) => {
		for await (const chunk of request) {
			void chunk;
		}
		if (mode === 'timeout') return;
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		response.write('data: {"type":"response.output_text.delta","delta":"SECRET-TEXT"}\r\n\r\n');
		if (mode !== 'missing')
			response.write(
				`data: ${JSON.stringify({ type: `response.${mode === 'over' ? 'completed' : 'incomplete'}`, response: { usage: { output_tokens: mode === 'over' ? 100 : 32 }, incomplete_details: { reason: 'max_output_tokens' } } })}\r\n\r\n`
			);
		response.end();
	});
	await new Promise((resolve) => upstream.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve));
	const model = { model: 'test', apiKey: 'SECRET-KEY', upstreamBaseUrl: `http://127.0.0.1:${upstream.address().port}` };
	try {
		await withBudgetRoute(model, async (url, captured) => {
			const result = await probe(url, { budget: 32 });
			assert.equal(result.terminal, 'incomplete');
			assert.equal(result.incompleteReason, 'max_output_tokens');
			assert.equal(result.outputTokens, 32);
			assert.deepEqual(captured[0], { max_output_tokens: 32 });
			assert.doesNotMatch(JSON.stringify(result), /SECRET/);
			const full = await probe(url, { budget: 32, full: true });
			assert.equal(full.verdict, 'reached-requested-budget');
			mode = 'missing';
			const missing = await probe(url, { budget: 32 });
			assert.equal(missing.verdict, 'failed');
			mode = 'over';
			const over = await probe(url, { budget: 32 });
			assert.equal(over.verdict, 'budget-not-respected');
			mode = 'timeout';
			const timeout = await probe(url, { budget: 32, timeoutMs: 30 });
			assert.equal(timeout.error, 'timeout-or-cancelled');
		});
	} finally {
		upstream.closeAllConnections();
		await new Promise((resolve) => upstream.close(resolve));
	}
});
