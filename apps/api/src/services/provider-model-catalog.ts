import { config } from 'src/config';
import { ProviderSettings } from 'src/database/provider-settings';
import { RequestBuilder } from 'src/proxy/request-builder';

import { OAuth } from '../auth/oauth';
import { OpenAIOAuthService } from '../auth/openai/openai-oauth-service';

import type { ModelMappingProvider, ProviderModelCatalogItem, ProviderModelsResponse } from '@ungate/shared';

const REQUEST_TIMEOUT_MS = 10_000;
const CLAUDE_PAGE_LIMIT = 1000;
const CLAUDE_MAX_PAGES = 100;

export class ProviderModelCatalogError extends Error {
	constructor(
		message: string,
		readonly statusCode: 401 | 502 | 504
	) {
		super(message);
		this.name = 'ProviderModelCatalogError';
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null;
}

function nonEmptyOr(value: string | undefined, fallback: string): string {
	if (value) return value;

	return fallback;
}

function itemFrom(value: unknown, idKey: string, labelKey: string): ProviderModelCatalogItem | null {
	if (!isRecord(value) || typeof value[idKey] !== 'string') {
		return null;
	}

	const upstreamModel = value[idKey].trim();
	if (!upstreamModel) {
		return null;
	}

	const rawLabel = typeof value[labelKey] === 'string' ? value[labelKey].trim() : '';

	return { upstreamModel, label: nonEmptyOr(rawLabel, upstreamModel) };
}

export function normalizeProviderModels(items: (ProviderModelCatalogItem | null)[]): ProviderModelCatalogItem[] {
	const seen = new Set<string>();
	const models: ProviderModelCatalogItem[] = [];

	for (const item of items) {
		if (!item) continue;

		const upstreamModel = item.upstreamModel.trim();
		const key = upstreamModel.toLowerCase();
		if (!upstreamModel || seen.has(key)) continue;

		const label = item.label.trim();
		seen.add(key);
		models.push({
			upstreamModel,
			label: nonEmptyOr(label, upstreamModel)
		});
	}

	return models;
}

async function fetchCatalogJson(url: string, headers: Record<string, string>): Promise<unknown> {
	try {
		const response = await fetch(url, {
			method: 'GET',
			headers,
			signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
		});

		if (response.status === 401 || response.status === 403) {
			throw new ProviderModelCatalogError('Provider authorization was rejected. Please reconnect the provider.', 401);
		}

		if (!response.ok) {
			throw new ProviderModelCatalogError(`Provider model catalog request failed with status ${response.status}.`, 502);
		}

		try {
			return await response.json();
		} catch {
			throw new ProviderModelCatalogError('Provider returned an invalid model catalog response.', 502);
		}
	} catch (error) {
		if (error instanceof ProviderModelCatalogError) throw error;

		if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
			throw new ProviderModelCatalogError('Provider model catalog request timed out.', 504);
		}

		throw new ProviderModelCatalogError('Unable to reach the provider model catalog.', 502);
	}
}

function claudeHeaders(accessToken: string): Record<string, string> {
	return {
		Accept: 'application/json',
		Authorization: `Bearer ${accessToken}`,
		'anthropic-beta': [
			config.anthropic.beta.claudeCode,
			config.anthropic.beta.oauth,
			config.anthropic.beta.interleavedThinking
		].join(','),
		'anthropic-dangerous-direct-browser-access': 'true',
		'anthropic-version': '2023-06-01',
		'User-Agent': 'claude-cli/2.1.9 (external, claude-vscode, agent-sdk/0.2.7)',
		'x-app': 'cli',
		...RequestBuilder.getStainlessHeaders()
	};
}

async function fetchClaudeModels(): Promise<ProviderModelCatalogItem[]> {
	const token = await OAuth.getValidToken();
	if (!token) {
		throw new ProviderModelCatalogError('Claude is not connected. Please connect the provider first.', 401);
	}

	const models: (ProviderModelCatalogItem | null)[] = [];
	const visitedCursors = new Set<string>();
	let afterId: string | null = null;
	let hasMore = true;

	for (let page = 0; page < CLAUDE_MAX_PAGES; page += 1) {
		const url = new URL('/v1/models', config.anthropic.apiUrl);
		url.searchParams.set('limit', String(CLAUDE_PAGE_LIMIT));
		url.searchParams.set('beta', 'true');
		if (afterId) url.searchParams.set('after_id', afterId);

		const payload = await fetchCatalogJson(url.toString(), claudeHeaders(token.accessToken));
		if (!isRecord(payload) || !Array.isArray(payload.data)) {
			throw new ProviderModelCatalogError('Claude returned an invalid model catalog response.', 502);
		}

		models.push(...payload.data.map((item) => itemFrom(item, 'id', 'display_name')));
		hasMore = payload.has_more === true;
		if (!hasMore) break;

		const lastId = typeof payload.last_id === 'string' ? payload.last_id.trim() : '';
		if (!lastId || visitedCursors.has(lastId)) {
			throw new ProviderModelCatalogError('Claude returned an invalid pagination cursor.', 502);
		}

		visitedCursors.add(lastId);
		afterId = lastId;
	}

	if (hasMore) {
		throw new ProviderModelCatalogError('Claude model catalog pagination exceeded the safety limit.', 502);
	}

	return normalizeProviderModels(models);
}

async function fetchMiniMaxModels(): Promise<ProviderModelCatalogItem[]> {
	const credentials = ProviderSettings.get('minimax');
	if (!credentials?.accessToken) {
		throw new ProviderModelCatalogError('MiniMax is not connected. Please connect the provider first.', 401);
	}

	const configuredBaseUrl = credentials.baseUrl?.trim();
	const baseUrl = nonEmptyOr(configuredBaseUrl, config.minimax.baseUrlGlobal).replace(/\/+$/, '');
	const payload = await fetchCatalogJson(`${baseUrl}/v1/models`, {
		Accept: 'application/json',
		Authorization: `Bearer ${credentials.accessToken}`
	});

	if (!isRecord(payload) || !Array.isArray(payload.data)) {
		throw new ProviderModelCatalogError('MiniMax returned an invalid model catalog response.', 502);
	}

	return normalizeProviderModels(payload.data.map((item) => itemFrom(item, 'id', 'name')));
}

async function fetchOpenAIModels(): Promise<ProviderModelCatalogItem[]> {
	const credentials = await OpenAIOAuthService.getValidToken();
	if (!credentials?.accessToken || !credentials.accountId) {
		throw new ProviderModelCatalogError('OpenAI is not connected. Please reconnect the provider.', 401);
	}

	const url = new URL(`${config.openai.codexUrl}/models`);
	const configuredClientVersion = process.env.CODEX_CLIENT_VERSION?.trim();
	url.searchParams.set('client_version', nonEmptyOr(configuredClientVersion, '0.0.0'));
	const payload = await fetchCatalogJson(url.toString(), {
		Accept: 'application/json',
		Authorization: `Bearer ${credentials.accessToken}`,
		'chatgpt-account-id': credentials.accountId,
		originator: 'codex_cli_rs'
	});

	if (!isRecord(payload) || !Array.isArray(payload.models)) {
		throw new ProviderModelCatalogError('OpenAI returned an invalid model catalog response.', 502);
	}

	return normalizeProviderModels(
		payload.models.map((item) => {
			if (!isRecord(item) || item.visibility !== 'list') return null;

			return itemFrom(item, 'slug', 'display_name');
		})
	);
}

export class ProviderModelCatalog {
	static async list(provider: ModelMappingProvider): Promise<ProviderModelsResponse> {
		const loaders: Record<ModelMappingProvider, () => Promise<ProviderModelCatalogItem[]>> = {
			claude: fetchClaudeModels,
			minimax: fetchMiniMaxModels,
			openai: fetchOpenAIModels
		};

		return { provider, models: await loaders[provider]() };
	}
}
