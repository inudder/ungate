import { existsSync, mkdtempSync, readFileSync, statSync } from 'node:fs';
import { register } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';

const DEFAULT_LIMITS = {
	claude: 200000,
	openai: 128000,
	gemini: 1000000,
	codex: 400000,
	hyperagent: 1000000,
	ha: 1000000
};
const FALLBACK_LIMIT = 128000;
let staticPromise = null;

function positiveInteger(value) {
	if (typeof value === 'string') {
		const trimmed = value.trim();
		if (!/^\d+$/.test(trimmed)) return null;
		value = Number(trimmed);
	}
	if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) return null;

	return value;
}

function providerEnvKey(provider) {
	return (
		'CONTEXT_LENGTH_' +
		String(provider)
			.toUpperCase()
			.replace(/[^A-Z0-9]/g, '_')
	);
}

function readEnvLimit(env, provider) {
	const specificKey = providerEnvKey(provider);
	if (Object.prototype.hasOwnProperty.call(env, specificKey)) {
		const parsed = positiveInteger(env[specificKey]);

		return parsed ? { limit: parsed, source: 'environment' } : { invalid: true };
	}
	if (Object.prototype.hasOwnProperty.call(env, 'CONTEXT_LENGTH_DEFAULT')) {
		const parsed = positiveInteger(env.CONTEXT_LENGTH_DEFAULT);

		return parsed ? { limit: parsed, source: 'environment' } : { invalid: true };
	}

	return null;
}

function nameHeuristic(model) {
	const lower = String(model || '').toLowerCase();
	if (lower.includes('claude')) return { limit: DEFAULT_LIMITS.claude, source: 'heuristic' };
	if (lower.includes('gemini')) return { limit: DEFAULT_LIMITS.gemini, source: 'heuristic' };
	if (lower.includes('gpt') || lower.includes('o1') || lower.includes('o3') || lower.includes('o4') || lower.includes('codex')) {
		return { limit: DEFAULT_LIMITS.codex, source: 'heuristic' };
	}

	return null;
}

function providerDefault(provider) {
	const limit = DEFAULT_LIMITS[String(provider || '').toLowerCase()];

	return limit ? { limit, source: 'provider-default' } : null;
}

function checksDisabled(value) {
	return value === true || value === 'true' || value === '1' || value === 'yes';
}

function splitRoute(route) {
	const slash = route.indexOf('/');
	if (slash <= 0 || slash === route.length - 1) return null;

	return { provider: route.slice(0, slash), model: route.slice(slash + 1) };
}

function concreteRoute(entry) {
	if (typeof entry === 'string') {
		const value = entry.trim();
		if (!value || value.includes('*') || value.startsWith('auto/')) return { incomplete: true };
		if (value.includes('/')) return { route: value };

		return { combo: value };
	}
	if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return { incomplete: true };
	if (entry.kind === 'provider-wildcard') return { incomplete: true };
	if (entry.kind === 'combo-ref') {
		const name = typeof entry.comboName === 'string' ? entry.comboName.trim() : '';
		if (!name || name.startsWith('auto/') || name.includes('*')) return { incomplete: true };

		return { combo: name };
	}
	const model = typeof entry.model === 'string' ? entry.model.trim() : '';
	if (!model || model.includes('*') || model.startsWith('auto/')) return { incomplete: true };
	if (model.includes('/')) return { route: model };
	const provider = String(entry.providerId || entry.provider || '').trim();
	if (!provider || provider.includes('*') || provider.startsWith('auto/')) return { incomplete: true };

	return { route: provider + '/' + model };
}

function expandCombo(name, combos, stack) {
	if (!name || name.startsWith('auto/') || stack.includes(name) || stack.length > 8) return null;
	const combo = combos.get(name);
	if (!combo || !Array.isArray(combo.models) || combo.models.length === 0) return null;
	const routes = [];
	for (const entry of combo.models) {
		const step = concreteRoute(entry);
		if (step.incomplete) return null;
		if (step.combo) {
			if (!combos.has(step.combo)) return null;
			const nested = expandCombo(step.combo, combos, stack.concat(name));
			if (!nested) return null;
			routes.push(...nested);
			continue;
		}
		if (!step.route || !splitRoute(step.route)) return null;
		routes.push(step.route);
	}

	return routes.length > 0 ? routes : null;
}

function rowsOf(request, name) {
	const fixture = request.fixture;
	if (!fixture || !Array.isArray(fixture[name])) return null;

	return fixture[name];
}

function openDatabase(dbPath) {
	if (!dbPath || !existsSync(dbPath)) return { error: 'missing' };
	try {
		return { db: new DatabaseSync(dbPath, { readOnly: true }) };
	} catch {
		return { error: 'unreadable' };
	}
}

function selectRows(db, sql, params) {
	try {
		return { rows: db.prepare(sql).all(...params) };
	} catch (error) {
		const message = String(error?.message ? error.message : error);
		if (message.includes('no such table')) return { rows: [] };

		return { error: 'query' };
	}
}

function loadCombos(request, db) {
	const fixture = rowsOf(request, 'combos');
	if (fixture) return { combos: new Map(fixture.map((combo) => [combo.name, combo])) };
	if (!db) return { combos: new Map() };
	const selected = selectRows(db, 'SELECT name, data FROM combos', []);
	if (selected.error) return { error: selected.error };
	const combos = new Map();
	for (const row of selected.rows) {
		try {
			const parsed = JSON.parse(row.data);
			const models = Array.isArray(parsed) ? parsed : parsed?.models;
			combos.set(row.name, { name: row.name, models: Array.isArray(models) ? models : [] });
		} catch {
			return { error: 'combo' };
		}
	}

	return { combos };
}

function findOverride(request, db, provider, model) {
	const fixture = rowsOf(request, 'contextOverrides');
	if (fixture) {
		return fixture.find((row) => row.provider === provider && row.modelId === model) || null;
	}
	if (!db) return null;
	const selected = selectRows(
		db,
		'SELECT real_context, source FROM model_context_overrides WHERE provider = ? AND model_id = ?',
		[provider, model]
	);
	if (selected.error) return { error: selected.error };

	return selected.rows[0] || null;
}

function findInputOverride(request, db, provider, model) {
	const fixture = rowsOf(request, 'inputOverrides');
	if (fixture) {
		return fixture.find((row) => row.provider === provider && row.modelId === model) || null;
	}
	if (!db) return null;
	const selected = selectRows(
		db,
		"SELECT value FROM model_capability_overrides WHERE provider = ? AND model_id = ? AND override_key = 'max_input_tokens'",
		[provider, model]
	);
	if (selected.error) return { error: selected.error };

	return selected.rows[0] || null;
}

function findCapability(request, db, provider, model) {
	const fixture = rowsOf(request, 'capabilities');
	if (fixture) {
		return fixture.find((row) => row.provider === provider && row.modelId === model) || null;
	}
	if (!db) return null;
	const selected = selectRows(
		db,
		'SELECT limit_context, limit_input FROM model_capabilities WHERE provider = ? AND model_id = ?',
		[provider, model]
	);
	if (selected.error) return { error: selected.error };

	return selected.rows[0] || null;
}

function readChecksFlag(request, db, env) {
	if (request.fixture && Object.prototype.hasOwnProperty.call(request.fixture, 'checksDisabled')) {
		return { disabled: checksDisabled(request.fixture.checksDisabled) };
	}
	if (db) {
		const selected = selectRows(
			db,
			"SELECT value FROM key_value WHERE namespace = 'feature_flags' AND key = 'DISABLE_CONTEXT_WINDOW_CHECKS'",
			[]
		);
		if (selected.error) return { disabled: false };
		if (selected.rows[0]) return { disabled: checksDisabled(selected.rows[0].value) };
	}

	return { disabled: checksDisabled(env.DISABLE_CONTEXT_WINDOW_CHECKS) };
}

function injectedStatic(request) {
	const staticCatalog = request.staticCatalog;
	if (!staticCatalog || staticCatalog.mode === 'installed') return null;
	if (staticCatalog.mode === 'unavailable') return { unavailable: true };

	return {
		authoritativeProvider: staticCatalog.authoritativeProvider || {},
		authoritativeModel: staticCatalog.authoritativeModel || {},
		registryContextLength: staticCatalog.registryContextLength || {},
		registryDefault: staticCatalog.registryDefault || {},
		specContextWindow: staticCatalog.specContextWindow || {}
	};
}

function staticValue(map, key) {
	if (!map || !Object.prototype.hasOwnProperty.call(map, key)) return null;
	const parsed = positiveInteger(map[key]);

	return parsed || null;
}

async function loadInstalledStatic(appRoot) {
	if (staticPromise) return staticPromise;
	staticPromise = (async () => {
		if (!appRoot || !existsSync(appRoot)) return { unavailable: true };
		const tempDir = mkdtempSync(path.join(os.tmpdir(), 'omniroute-static-'));
		const previousDataDir = process.env.DATA_DIR;
		process.env.OMNIROUTE_APP_ROOT = appRoot;
		process.env.DATA_DIR = tempDir;
		const liveDatabase = process.env.OMNIROUTE_LIVE_DATABASE;
		const liveBefore = liveDatabase && existsSync(liveDatabase) ? statSync(liveDatabase).mtimeMs : null;
		try {
			await register(new URL('./omniroute-static-hooks.mjs', import.meta.url).href);
			const specs = await import(pathToFileURL(path.join(appRoot, 'src/shared/constants/modelSpecs.ts')).href);
			const registry = await import(pathToFileURL(path.join(appRoot, 'open-sse/config/providers/index.ts')).href);
			if (existsSync(path.join(tempDir, 'storage.sqlite'))) return { unavailable: true };
			if (liveBefore !== null && statSync(liveDatabase).mtimeMs !== liveBefore) return { unavailable: true };

			return { specs, registry: registry.REGISTRY };
		} catch {
			return { unavailable: true };
		} finally {
			if (previousDataDir === undefined) delete process.env.DATA_DIR;
			else process.env.DATA_DIR = previousDataDir;
		}
	})();

	return staticPromise;
}

function catalogFromInstalled(loaded, provider, model) {
	if (!loaded || loaded.unavailable) return { unavailable: true };
	const providerKey = (provider + '/' + model).toLowerCase();
	const authoritativeProvider = loaded.specs.getAuthoritativeProviderContextWindow(provider, model);
	if (positiveInteger(authoritativeProvider)) return { limit: authoritativeProvider, source: 'authoritative' };
	const authoritativeModel = loaded.specs.getAuthoritativeContextWindow(model);
	if (positiveInteger(authoritativeModel)) return { limit: authoritativeModel, source: 'authoritative' };
	const registryEntries = Object.values(loaded.registry || {}).filter((entry) => {
		return entry && (entry === loaded.registry[provider] || entry.id === provider || entry.alias === provider);
	});
	for (const entry of registryEntries) {
		if (!Array.isArray(entry.models)) continue;
		const found = entry.models.find((item) => item && item.id === model);
		const contextLength = positiveInteger(found?.contextLength);
		if (contextLength) return { limit: contextLength, source: 'registry' };
	}
	const spec = loaded.specs.getModelSpec(model);
	const specWindow = positiveInteger(spec?.contextWindow);
	if (specWindow) return { limit: specWindow, source: 'spec' };
	const registryDefault = registryEntries.map((entry) => positiveInteger(entry.defaultContextLength)).find((value) => value);
	if (registryDefault) return { limit: registryDefault, source: 'registry-default' };

	return { missed: true, providerKey };
}

function catalogFromInjected(staticCatalog, provider, model) {
	if (staticCatalog.unavailable) return { unavailable: true };
	const providerKey = provider + '/' + model;
	const authoritativeProvider = staticValue(staticCatalog.authoritativeProvider, providerKey);
	if (authoritativeProvider) return { limit: authoritativeProvider, source: 'authoritative' };
	const authoritativeModel = staticValue(staticCatalog.authoritativeModel, model);
	if (authoritativeModel) return { limit: authoritativeModel, source: 'authoritative' };
	const registryContext = staticValue(staticCatalog.registryContextLength, providerKey);
	if (registryContext) return { limit: registryContext, source: 'registry' };
	const specWindow = staticValue(staticCatalog.specContextWindow, model);
	if (specWindow) return { limit: specWindow, source: 'spec' };
	const registryDefault = staticValue(staticCatalog.registryDefault, provider);
	if (registryDefault) return { limit: registryDefault, source: 'registry-default' };

	return { missed: true };
}

function resolveContext(parts) {
	const envLimit = readEnvLimit(parts.env, parts.provider);
	if (envLimit?.invalid) return { status: 'unconfirmed' };
	if (envLimit) return { status: 'confirmed', context: envLimit };

	const override = parts.override;
	if (override?.error) return { status: 'unconfirmed' };
	if (override) {
		const limit = positiveInteger(override.realContext ?? override.real_context);
		const source = override.source === 'auto:discovery' ? 'auto:discovery' : override.source === 'manual' ? 'manual' : null;
		if (!limit || !source) return { status: 'unconfirmed' };

		return { status: 'confirmed', context: { limit, source } };
	}

	const catalog = parts.catalog;
	if (!catalog || catalog.unavailable) return { status: 'unconfirmed' };
	if (catalog.limit) return { status: 'confirmed', context: { limit: catalog.limit, source: catalog.source } };

	const capability = parts.capability;
	if (capability?.error) return { status: 'unconfirmed' };
	const synced = positiveInteger(capability && (capability.limitContext ?? capability.limit_context));
	if (synced) return { status: 'confirmed', context: { limit: synced, source: 'limit_context' } };

	return {
		status: 'confirmed',
		context: nameHeuristic(parts.model) || providerDefault(parts.provider) || { limit: FALLBACK_LIMIT, source: 'fallback' }
	};
}

function resolveInput(parts, contextLimit) {
	const override = parts.inputOverride;
	if (override?.error) return { status: 'unconfirmed' };
	if (override) {
		const limit = positiveInteger(override.value ?? override.realContext);
		if (!limit) return { status: 'unconfirmed' };

		return { status: 'confirmed', maxInput: { limit, source: 'max_input_tokens' } };
	}
	const capability = parts.capability;
	if (capability?.error) return { status: 'unconfirmed' };
	const limitInput = positiveInteger(capability && (capability.limitInput ?? capability.limit_input));
	if (!limitInput) return { status: 'confirmed', maxInput: null };
	const limit = contextLimit ? Math.min(limitInput, contextLimit) : limitInput;

	return { status: 'confirmed', maxInput: { limit, source: 'limit_input' } };
}

async function resolvePhysical(request, db, route) {
	const parsed = splitRoute(route);
	if (!parsed) return { status: 'unconfirmed' };
	const override = findOverride(request, db, parsed.provider, parsed.model);
	const inputOverride = findInputOverride(request, db, parsed.provider, parsed.model);
	const capability = findCapability(request, db, parsed.provider, parsed.model);
	if (override?.error || inputOverride?.error || capability?.error) {
		return { status: 'unconfirmed' };
	}
	const injected = injectedStatic(request);
	let catalog = injected;
	if (!catalog) {
		const loaded = await loadInstalledStatic(request.appRoot);
		catalog = catalogFromInstalled(loaded, parsed.provider, parsed.model);
	} else {
		catalog = catalogFromInjected(injected, parsed.provider, parsed.model);
	}
	const context = resolveContext({
		env: request.listenerEnv || {},
		provider: parsed.provider,
		model: parsed.model,
		override,
		capability,
		catalog
	});
	if (context.status !== 'confirmed') return { status: 'unconfirmed', route };
	const maxInput = resolveInput({ inputOverride, capability }, context.context.limit);
	if (maxInput.status !== 'confirmed') return { status: 'unconfirmed', route };

	return {
		status: 'confirmed',
		route,
		context: context.context,
		maxInput: maxInput.maxInput
	};
}

async function resolveRequest(request) {
	if (request.staticProbe) {
		const loaded = await loadInstalledStatic(request.appRoot);

		return { status: loaded && !loaded.unavailable ? 'ready' : 'unavailable' };
	}
	if (request.listenerEnvReadable !== true) return { status: 'unconfirmed' };
	const env = request.listenerEnv || {};
	const opened = request.fixture ? { db: null } : openDatabase(request.dbPath);
	if (opened.error) return { status: 'unconfirmed' };
	const flag = readChecksFlag(request, opened.db, env);
	if (flag.disabled) return { status: 'checks-disabled' };
	const route = typeof request.route === 'string' ? request.route.trim() : '';
	if (!route) return { status: 'unconfirmed' };
	let routes = [route];
	if (!route.includes('/')) {
		if (route.startsWith('auto/')) return { status: 'unconfirmed' };
		const loaded = loadCombos(request, opened.db);
		if (loaded.error || !loaded.combos.has(route)) return { status: 'unconfirmed' };
		const expanded = expandCombo(route, loaded.combos, []);
		if (!expanded) return { status: 'unconfirmed' };
		routes = expanded;
	}
	const targets = [];
	for (const targetRoute of routes) {
		const resolved = await resolvePhysical(request, opened.db, targetRoute);
		if (resolved.status !== 'confirmed') return { status: 'unconfirmed' };
		targets.push(resolved);
	}

	return { status: 'confirmed', combo: routes.length !== 1 || routes[0] !== route, targets };
}

const requestPath = process.argv[2];
if (!requestPath) {
	process.stdout.write(JSON.stringify({ status: 'unconfirmed' }));
	process.exit(0);
}
const request = JSON.parse(readFileSync(requestPath, 'utf8'));
const result = await resolveRequest(request);
process.stdout.write(JSON.stringify(result));
