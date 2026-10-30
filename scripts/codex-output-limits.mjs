import { createHash, randomUUID } from 'node:crypto';
import { access, readFile, readdir, mkdir, rename, writeFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

import { createShellRouterServer } from './codex-model-shell-router.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const FIELDS = ['max_output_tokens', 'max_tokens', 'max_completion_tokens'];
const hash = (value) => createHash('sha256').update(value).digest('hex');
const positive = (value) => Number.isSafeInteger(value) && value > 0;
const budgets = (body) => Object.fromEntries(FIELDS.filter((key) => positive(body?.[key])).map((key) => [key, body[key]]));

export function outputFingerprint(value) {
	const stable = (entry) => {
		if (Array.isArray(entry)) return entry.map(stable);
		if (entry && typeof entry === 'object')
			return Object.fromEntries(
				Object.keys(entry)
					.sort()
					.map((key) => [key, stable(entry[key])])
			);

		return entry;
	};

	return hash(JSON.stringify(stable(value)));
}

async function fileHash(filename) {
	try {
		const bytes = await readFile(filename);

		return hash(bytes);
	} catch {
		return null;
	}
}

// Never emit arbitrary provider responses, configuration or prompts into receipts.
function localRequest(url, body, signal) {
	const target = new URL(url);
	if (target.protocol !== 'http:' || target.hostname !== '127.0.0.1') throw new Error('Expected local HTTP endpoint.');

	return new Promise((resolve, reject) => {
		const request = http.request(
			target,
			{
				method: body === undefined ? 'GET' : 'POST',
				signal,
				headers: body === undefined ? {} : { 'content-type': 'application/json' }
			},
			resolve
		);
		request.on('error', reject);
		request.end(body === undefined ? undefined : JSON.stringify(body));
	});
}

async function localJson(url) {
	const response = await localRequest(url, undefined, AbortSignal.timeout(2000));
	if (response.statusCode !== 200) {
		response.destroy();
		throw new Error('Local health unavailable.');
	}
	let text = '';
	for await (const chunk of response) {
		text += chunk;
		if (text.length > 1000000) {
			response.destroy();
			throw new Error('Oversized health.');
		}
	}

	return JSON.parse(text);
}

async function listen(server) {
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve);
	});

	return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
	if (!server.listening) return;
	await new Promise((resolve) => {
		server.close(resolve);
		server.closeAllConnections();
	});
}

// Isolate the launcher router only. Use the configured gateway/CLIProxy bridge unchanged.
// The tap retains budget fields, never credentials, prompt text or generated content.
export async function withBudgetRoute(model, callback, { offline = false } = {}) {
	const captured = [];
	const upstreamRequests = new Set();
	const tap = http.createServer(async (request, response) => {
		try {
			const chunks = [];
			for await (const chunk of request) chunks.push(chunk);
			const bytes = Buffer.concat(chunks);
			captured.push(budgets(JSON.parse(bytes.toString('utf8'))));
			if (offline) {
				response.writeHead(200, { 'content-type': 'application/json' });
				response.end(JSON.stringify({ id: 'budget-inspection', object: 'response', status: 'completed', output: [] }));

				return;
			}
			const target = new URL(request.url, model.upstreamBaseUrl);
			if (target.protocol !== 'http:' || target.hostname !== '127.0.0.1') throw new Error('Nonlocal gateway.');
			const outgoing = http.request(
				target,
				{ method: 'POST', headers: { ...request.headers, host: target.host } },
				(incoming) => {
					response.writeHead(incoming.statusCode, incoming.headers);
					incoming.on('error', () => response.destroy());
					incoming.pipe(response);
				}
			);
			upstreamRequests.add(outgoing);
			outgoing.on('close', () => upstreamRequests.delete(outgoing));
			outgoing.on('error', () => {
				if (!response.headersSent) response.writeHead(502);
				response.end();
			});
			response.on('close', () => outgoing.destroy());
			outgoing.end(bytes);
		} catch {
			if (!response.headersSent) response.writeHead(502);
			response.end();
		}
	});
	let router;
	try {
		const tapUrl = await listen(tap);
		router = createShellRouterServer({
			logger: () => {},
			routes: [
				{
					clientModel: 'output-budget-probe',
					upstreamModel: model.model,
					upstreamBaseUrl: tapUrl,
					apiKey: offline ? 'offline-inspection' : model.apiKey,
					responsesAdapter: model.responsesAdapter,
					parallelToolCalls: model.parallelToolCalls
				}
			]
		});
		const baseUrl = await listen(router);
		const health = await localJson(`${baseUrl}/_shell-router/health`);
		if (health.pid !== process.pid || health.service !== 'codex-model-shell-router')
			throw new Error('Diagnostic identity mismatch.');

		return await callback(baseUrl, captured);
	} finally {
		for (const request of upstreamRequests) request.destroy();
		if (router) await close(router);
		await close(tap);
	}
}

export function evaluatePolicy({ routerBudget = {}, rules = {}, provider, model, defaults = [], cap = null }) {
	let selected = { ...routerBudget };
	let source = Object.keys(selected).length ? 'launcher router' : null;
	let uncertain = false;
	const matches = (rule) =>
		!Array.isArray(rule.models) ||
		rule.models.some((entry) => {
			if (entry.protocol && entry.protocol !== provider) return false;
			if (entry.name === model) return true;
			if (!entry.name || entry.name.includes('*')) {
				uncertain = true;

				return true;
			}

			return false;
		});
	// Complex rules require executor-specific inspection, not a guessed precedence.
	for (const key of ['override', 'filter', 'defaultRaw', 'overrideRaw']) {
		if ((rules[key] || []).some(matches)) uncertain = true;
	}
	const variants = defaults.map((entry) => JSON.stringify(budgets(entry ?? {})));
	if (new Set(variants).size > 1) uncertain = true;
	if (!Object.keys(selected).length && defaults.length && Object.keys(budgets(defaults[0])).length) {
		selected = budgets(defaults[0]);
		source = 'provider requestDefaults';
	}
	for (const rule of rules.default || []) {
		if (!matches(rule)) continue;
		const values = budgets(rule.params);
		if (Object.keys(values).length > 1) uncertain = true;
		if (!Object.keys(selected).length && Object.keys(values).length) {
			selected = values;
			source = 'OmniRoute payload default';
		}
	}
	const values = Object.values(selected);
	if (values.length > 1) uncertain = true;
	const configured = !uncertain && values.length === 1 ? Math.min(values[0], positive(cap) ? cap : Infinity) : null;

	return { fields: selected, configured, source, cap: positive(cap) ? cap : null, uncertain, finalUpstreamVerified: false };
}

export function readOmniPolicy(filename, requestModel, routerBudget) {
	const db = new DatabaseSync(filename, { readOnly: true });
	try {
		const get = (namespace, key) => {
			const row = db.prepare('SELECT value FROM key_value WHERE namespace = ? AND key = ?').get(namespace, key);

			return row ? JSON.parse(row.value) : null;
		};
		const route = get('modelAliases', requestModel) ?? requestModel;
		if (typeof route !== 'string' || !route.includes('/')) throw new Error('Unresolved alias or combo.');
		const slash = route.indexOf('/');
		let provider = route.slice(0, slash);
		const model = route.slice(slash + 1);
		const node = db
			.prepare('SELECT id, base_url, api_type, chat_path FROM provider_nodes WHERE prefix = ? OR id = ?')
			.get(provider, provider);
		provider = node?.id ?? provider;
		const connections = db
			.prepare('SELECT id, provider_specific_data FROM provider_connections WHERE provider = ? AND is_active = 1 ORDER BY id')
			.all(provider);
		const defaults = connections.map((entry) => JSON.parse(entry.provider_specific_data || '{}').requestDefaults ?? {});
		const rules = get('settings', 'payloadRules') ?? {};
		const overrides = db
			.prepare(
				'SELECT override_key, override_value FROM model_capability_overrides WHERE provider = ? AND model_id = ? ORDER BY override_key'
			)
			.all(provider, model);
		const cap = Number(overrides.find((entry) => entry.override_key === 'max_output_tokens')?.override_value);

		return {
			...evaluatePolicy({ routerBudget, rules, provider, model, defaults, cap }),
			resolvedRoute: `${provider}/${model}`,
			// Hash settings in memory; do not persist arbitrary params or provider data.
			settingsHash: hash(JSON.stringify({ route, node, connections, rules, overrides }))
		};
	} finally {
		db.close();
	}
}

export function selectEvidence(entries, model, now = Date.now()) {
	const entry = entries.findLast(
		(item) => item.transport === model.transport && item.model === model.model && item.upstreamBaseUrl === model.upstreamBaseUrl
	);
	if (!entry) return null;
	const age = now - Date.parse(entry.checkedAt);
	if (
		!positive(entry.maximum) ||
		!(entry.source || '').startsWith('https://') ||
		!Number.isFinite(age) ||
		age < -86400000 ||
		age > 30 * 86400000
	)
		return null;

	return { maximum: entry.maximum, source: entry.source, checkedAt: entry.checkedAt };
}

async function inspect(config, model) {
	const routerBudget = await withBudgetRoute(
		model,
		async (baseUrl, captured) => {
			const response = await localRequest(
				`${baseUrl}/v1/responses`,
				{ model: 'output-budget-probe', input: 'Budget inspection.', stream: false },
				AbortSignal.timeout(5000)
			);
			for await (const chunk of response) {
				void chunk; // Drain the synthetic reply.
			}

			return captured[0] ?? {};
		},
		{ offline: true }
	);
	let policy = { ...evaluatePolicy({ routerBudget }), settingsHash: null };
	let inspectionError = null;
	const legacyRoot = path.join(process.env.USERPROFILE || '', '.omniroute');
	const defaultRoot = path.join(process.env.APPDATA || '', 'OmniRoute');
	const legacyExists = await access(path.join(legacyRoot, 'storage.sqlite')).then(
		() => true,
		() => false
	);
	const omniRoot = config.omniRoot ?? (legacyExists ? legacyRoot : defaultRoot);
	if (model.transport === 'omniroute') {
		try {
			if (model.upstreamBaseUrl !== 'http://127.0.0.1:20128' && !config.omniRoot) throw new Error('Unverified gateway database.');
			policy = readOmniPolicy(path.join(omniRoot, 'storage.sqlite'), model.model, routerBudget);
		} catch {
			inspectionError = 'OmniRoute: настройки или точный маршрут не прочитаны';
			policy.uncertain = true;
			policy.configured = null;
		}
	} else if (model.transport === 'cliproxyapi') {
		try {
			const text = await readFile(config.cliProxyConfigPath, 'utf8');
			policy.settingsHash = hash(text);
			// Never interpret arbitrary YAML as a known executor's effective payload.
			if (/^\s*(payload|max_tokens|max_output_tokens|max_completion_tokens)\s*:/m.test(text)) {
				inspectionError = 'CLIProxy: есть payload-настройки; нужен разбор executor';
				policy.uncertain = true;
				policy.configured = null;
			}
		} catch {
			inspectionError = 'CLIProxy: конфигурация недоступна';
			policy.uncertain = true;
		}
	} else {
		inspectionError = 'Автоматический разбор настроек этого транспорта не поддержан';
		policy.uncertain = true;
	}
	const files = [
		'codex-model-shell-router.mjs',
		'codex-agent-messages.mjs',
		'codex-tools-schema-cache.mjs',
		'mimo-responses-namespace.mjs',
		'mimo-responses-stream-adapter.mjs',
		'deepseek-responses-adapter.mjs',
		'cliproxy-namespace-bridge.mjs',
		'codex-output-limits.mjs'
	];
	const hashes = await Promise.all(files.map(async (name) => [name, await fileHash(path.join(ROOT, name))]));
	const code = Object.fromEntries(hashes);
	const gatewayVersion =
		model.transport === 'cliproxyapi'
			? await fileHash(path.join(path.dirname(config.cliProxyConfigPath), 'cli-proxy-api.exe'))
			: await fileHash(path.join(process.env.LOCALAPPDATA || '', 'Programs/OmniRoute/resources/app/package.json'));
	let runtimeMatches = false;
	try {
		const health = await localJson(`${config.routerBaseUrl}/_shell-router/health`);
		runtimeMatches = health.status === 'ok' && health.build_id === code['codex-model-shell-router.mjs'];
	} catch {
		/* A stopped router does not block configuration inspection. */
	}
	const templateText = await readFile(path.join(ROOT, 'codex-desktop-launcher/output-limits.default.json'), 'utf8');
	const template = JSON.parse(templateText);
	let entries = template.models;
	try {
		const evidenceText = await readFile(config.evidencePath, 'utf8');
		entries = entries.concat(JSON.parse(evidenceText).models);
	} catch (error) {
		if (error.code !== 'ENOENT') inspectionError = 'Файл источников максимума повреждён';
	}
	const evidence = selectEvidence(entries, model);
	const identity = { ...model };
	delete identity.apiKey;
	const snapshot = { model: identity, policy, evidence, code, gatewayVersion, runtimeMatches, inspectionError };

	return { ...snapshot, fingerprint: outputFingerprint(snapshot), inspectedAt: new Date().toISOString() };
}

export function assessProbe(result, requested, full = false) {
	if (result.error || result.httpStatus !== 200 || !result.terminal || result.terminal === 'failed') return 'failed';
	if (result.terminal === 'incomplete' && result.incompleteReason !== 'max_output_tokens') return 'inconclusive';
	if (!positive(requested) && result.terminal === 'incomplete') return 'default-truncated';
	if (positive(requested) && result.outputTokens > requested) return 'budget-not-respected';
	if (full) return positive(requested) && result.outputTokens === requested ? 'reached-requested-budget' : 'inconclusive';

	return positive(requested) ? 'request-accepted-not-maximum-proof' : 'default-request-completed';
}

export async function probe(baseUrl, { budget, full = false, reasoning, timeoutMs = 180000 } = {}) {
	const body = {
		model: 'output-budget-probe',
		stream: true,
		input: full
			? 'Generate an extremely long numbered list of distinct short sentences about integers. Continue until the output token limit. Do not summarize or finish early.'
			: 'Reply with exactly OK.'
	};
	if (positive(budget)) body.max_output_tokens = budget;
	if (reasoning) body.reasoning = { effort: reasoning };
	const result = {
		requestedBudget: budget ?? null,
		full,
		httpStatus: null,
		terminal: null,
		outputTokens: null,
		incompleteReason: null,
		terminalEvents: []
	};
	const accept = (event) => {
		const response = event.response ?? event;
		if (['response.completed', 'response.incomplete', 'response.failed'].includes(event.type)) {
			result.terminalEvents.push(event.type);
			// Preserve an invalid extra failed terminal instead of hiding it.
			result.terminal = event.type.slice('response.'.length);
		} else if (!event.type && ['completed', 'incomplete', 'failed'].includes(response.status)) result.terminal = response.status;
		if (Number.isSafeInteger(response.usage?.output_tokens)) result.outputTokens = response.usage.output_tokens;
		const reason = response.incomplete_details?.reason;
		if (['max_output_tokens', 'content_filter'].includes(reason)) result.incompleteReason = reason;
	};
	try {
		const response = await localRequest(`${baseUrl}/v1/responses`, body, AbortSignal.timeout(timeoutMs));
		result.httpStatus = response.statusCode;
		if (response.statusCode !== 200) {
			response.destroy();
			result.error = 'http-error';
		} else {
			const sse = String(response.headers['content-type']).includes('text/event-stream');
			let pending = '';
			let bytes = 0;
			const decoder = new TextDecoder();
			for await (const chunk of response) {
				bytes += chunk.length;
				if (bytes > 64 * 1024 * 1024) {
					response.destroy();
					throw new Error('size');
				}
				pending += decoder.decode(chunk, { stream: true }).replace(/\r/g, '');
				if (sse) {
					let end;
					while ((end = pending.indexOf('\n\n')) >= 0) {
						const event = pending.slice(0, end);
						pending = pending.slice(end + 2);
						const data = event
							.split('\n')
							.filter((line) => line.startsWith('data:'))
							.map((line) => line.slice(5).trimStart())
							.join('\n');
						if (data && data !== '[DONE]') accept(JSON.parse(data));
					}
				}
				if (pending.length > 4 * 1024 * 1024) {
					response.destroy();
					throw new Error('event-size');
				}
			}
			if (!sse && pending) accept(JSON.parse(pending));
		}
	} catch (error) {
		result.error = error.name === 'AbortError' ? 'timeout-or-cancelled' : 'transport-or-stream-error';
	}
	result.verdict = assessProbe(result, budget, full);

	return result;
}

export function cacheState(report, snapshot, now = Date.now()) {
	if (!report) return 'missing';
	const age = now - Date.parse(report.completedAt);
	if (report.fingerprint !== snapshot.fingerprint || !Number.isFinite(age) || age < 0 || age > 7 * 86400000) return 'stale';

	if (!report.checks?.length) return 'missing';

	return report.checks.some((check) =>
		['failed', 'budget-not-respected', 'inconclusive', 'default-truncated'].includes(check.verdict)
	)
		? 'failed'
		: 'current';
}

async function latestReport(directory, model) {
	try {
		const names = await readdir(directory);
		for (const name of names
			.filter((name) => name.endsWith('.json'))
			.sort()
			.reverse()) {
			const reportText = await readFile(path.join(directory, name), 'utf8');
			const report = JSON.parse(reportText);
			if (report.snapshot?.model.registryId === model.registryId) return report;
		}
	} catch {
		/* No readable evidence means unverified. */
	}

	return null;
}

export function recommendation(snapshot, previous, state) {
	const limit = snapshot.evidence?.maximum;
	const current = snapshot.policy.configured;
	if (positive(limit) && positive(current) && current < limit) {
		const accepted =
			state === 'current' &&
			previous.checks.some(
				(check) =>
					check.requestedBudget === limit &&
					['request-accepted-not-maximum-proof', 'reached-requested-budget'].includes(check.verdict)
			);

		return accepted
			? `Можно повысить дефолт с ${current} до ${limit}: запрос с этим бюджетом принят. Полная длина отдельно не доказана.`
			: `Дефолт ${current} ниже заявленных ${limit}. Сначала проверьте принятие большего бюджета (-TestOutputLimits).`;
	}
	if (!positive(current)) return 'Бюджет по настройкам не установлен/не подтверждён; это не означает безлимит.';
	if (!positive(limit)) return 'Максимум провайдера неизвестен; оснований советовать повышение пока нет.';
	if (current > limit) return 'Настроенный бюджет выше заявленного максимума; проверьте ограничение или отказ upstream.';

	return 'Дефолт соответствует заявленному максимуму; фактический выход подтверждается отдельно.';
}

export async function runOutputLimits(config, { log = console.log } = {}) {
	let exitCode = 0;
	for (const model of config.models) {
		const snapshot = await inspect(config, model);
		const previous = await latestReport(config.reportDirectory, model);
		const state = cacheState(previous, snapshot);
		log(`\n${model.displayName} [${model.model}]`);
		log(
			`  Бюджет по настройкам: ${snapshot.policy.configured ?? 'неизвестен'}; поле: ${Object.keys(snapshot.policy.fields).join(', ') || 'не задано'}; источник: ${snapshot.policy.source ?? 'upstream default неизвестен'}.`
		);
		log(
			`  Заявленный максимум: ${snapshot.evidence?.maximum ?? 'неизвестен'}${snapshot.evidence ? ` (${snapshot.evidence.source}; ${snapshot.evidence.checkedAt})` : ''}.`
		);
		log(
			`  Прошлый тест: ${state}; ${previous?.completedAt ?? 'нет даты'}. Роутер совпадает с работающей сборкой: ${snapshot.runtimeMatches ? 'да' : 'не подтверждено'}.`
		);
		log(`  ${recommendation(snapshot, previous, state)}`);
		if (snapshot.inspectionError) log(`  Внимание: ${snapshot.inspectionError}.`);
		if (state === 'current') {
			for (const check of previous.checks) log(`  ${check.name}: ${check.verdict}, выдано ${check.outputTokens ?? '?'} токенов.`);
		}
		if (
			!snapshot.evidence ||
			!snapshot.policy.configured ||
			snapshot.policy.uncertain ||
			state !== 'current' ||
			!snapshot.runtimeMatches
		)
			exitCode = 2;
		if (!config.probe) continue;
		const candidate = config.budget || snapshot.evidence?.maximum;
		if (config.full && !positive(candidate)) throw new Error('Full output test requires a positive candidate budget.');
		if (!model.apiKey) throw new Error('Provider credentials unavailable.');
		const report = {
			version: 1,
			snapshot,
			fingerprint: snapshot.fingerprint,
			startedAt: new Date().toISOString(),
			checks: [],
			completedAt: null
		};
		await mkdir(config.reportDirectory, { recursive: true });
		const filename = path.join(config.reportDirectory, `${report.startedAt.replace(/[:.]/g, '-')}_${randomUUID()}.json`);
		const save = async () => {
			const temporary = `${filename}.${randomUUID()}.tmp`;
			await writeFile(temporary, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
			await rename(temporary, filename);
		};
		await save();
		log(`  Тест через отдельный router → текущий bridge/gateway; отчёт: ${filename}`);
		try {
			await withBudgetRoute(model, async (baseUrl, captured) => {
				const checks = [
					{ name: 'default', budget: undefined },
					{ name: 'explicit-small', budget: 32 }
				];
				if (positive(candidate))
					checks.push({ name: config.full ? 'full-output' : 'candidate', budget: candidate, full: !!config.full });
				for (const check of checks) {
					const result = await probe(baseUrl, { ...check, reasoning: model.reasoning, timeoutMs: config.timeoutMs });
					report.checks.push({ name: check.name, ...result, routerOutgoingBudget: captured.at(-1) ?? {} });
					log(
						`  ${check.name}: ${result.verdict}; HTTP ${result.httpStatus}; ${result.terminal ?? 'нет terminal'}; output=${result.outputTokens ?? '?'}.`
					);
					await save();
					if (result.error) break;
				}
			});
		} catch {
			report.checks.push({ name: 'route', verdict: 'failed', error: 'diagnostic-route-error' });
		} finally {
			report.completedAt = new Date().toISOString();
			await save();
		}
		if (!candidate)
			log('  Максимум неизвестен: выполнены только default и explicit-small. Укажите -OutputTokenBudget для проверки кандидата.');
		log('  Принятый параметр не доказывает отсутствие скрытого ограничения upstream. Настройки не изменены.');
		exitCode =
			report.checks.some((check) =>
				['failed', 'budget-not-respected', 'inconclusive', 'default-truncated'].includes(check.verdict)
			) || !candidate
				? 2
				: 0;
	}

	return exitCode;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	try {
		let input = '';
		for await (const chunk of process.stdin) input += chunk;
		process.exitCode = await runOutputLimits(JSON.parse(input));
	} catch {
		console.error('Output-limit diagnostics failed. Check local configuration/credentials and preserved receipts.');
		process.exitCode = 2;
	}
}
