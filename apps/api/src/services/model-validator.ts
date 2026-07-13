import { openaiToAnthropic } from '../adapter/openai-to-anthropic';
import { OAuth } from '../auth/oauth';
import { OpenAIOAuthService } from '../auth/openai';
import { ProviderSettings } from '../database/provider-settings';
import { CompletionErrorMapper, CompletionModelRouting } from '../orchestration/openai';
import { makeClaudeCodeRequest } from '../proxy/anthropic-client';
import { proxyMiniMaxRequest } from '../proxy/minimax-client';
import { proxyOpenAIRequest } from '../proxy/proxy-client';

import type { OpenAIChatRequest } from '../types/openai';
import type { ModelMappingConfig, ModelValidationResult } from '@ungate/shared';

function probeBody(model: string): OpenAIChatRequest {
	return {
		model,
		messages: [{ role: 'user', content: 'ping' }],
		max_tokens: 16,
		stream: false
	};
}

async function readErrorMessage(response: Response): Promise<string> {
	const json = await response
		.clone()
		.json()
		.catch(() => null);
	const err = json as { error?: { message?: string } } | null;

	return err?.error?.message ?? `HTTP ${response.status}`;
}

export class ModelValidator {
	static async validate(model: ModelMappingConfig): Promise<ModelValidationResult> {
		const upstreamModel = model.upstreamModel.trim();

		if (!model.id.trim() || !upstreamModel) {
			return {
				ok: false,
				available: false,
				message: 'Model ID and upstream model are required.',
				provider: model.provider,
				upstreamModel
			};
		}

		if (model.provider === 'claude') {
			return this.validateClaude(model, upstreamModel);
		}

		if (model.provider === 'minimax') {
			return this.validateMiniMax(model, upstreamModel);
		}

		return this.validateOpenAi(model, upstreamModel);
	}

	private static async validateClaude(model: ModelMappingConfig, upstreamModel: string): Promise<ModelValidationResult> {
		if (!OAuth.getAuthStatus().authenticated) {
			return { ok: true, available: false, message: 'Claude is not logged in.', provider: 'claude', upstreamModel };
		}

		const anthropicBody = openaiToAnthropic(probeBody(upstreamModel), {
			model: upstreamModel,
			reasoningBudget: model.reasoningBudget
		});
		const startTime = Date.now();
		const result = await makeClaudeCodeRequest('/v1/messages', anthropicBody, {});
		const latencyMs = Date.now() - startTime;

		if (result.success && result.response.ok) {
			return {
				ok: true,
				available: true,
				message: 'Model is available.',
				provider: 'claude',
				upstreamModel,
				statusCode: result.response.status,
				latencyMs
			};
		}

		if (result.success) {
			const message = await readErrorMessage(result.response);

			return {
				ok: true,
				available: false,
				message,
				provider: 'claude',
				upstreamModel,
				statusCode: result.response.status,
				latencyMs
			};
		}

		return {
			ok: true,
			available: false,
			message: result.error,
			provider: 'claude',
			upstreamModel,
			statusCode: result.status,
			latencyMs
		};
	}

	private static async validateMiniMax(model: ModelMappingConfig, upstreamModel: string): Promise<ModelValidationResult> {
		const creds = ProviderSettings.get('minimax');

		if (!creds?.accessToken) {
			return { ok: true, available: false, message: 'MiniMax API key is not configured.', provider: 'minimax', upstreamModel };
		}

		const minimaxBody = CompletionModelRouting.buildMiniMaxBody(probeBody(model.id), model);
		const startTime = Date.now();
		const { response, context } = await proxyMiniMaxRequest(minimaxBody);
		const latencyMs = Date.now() - startTime;

		if (response.ok) {
			return {
				ok: true,
				available: true,
				message: 'Model is available.',
				provider: 'minimax',
				upstreamModel,
				statusCode: response.status,
				latencyMs
			};
		}

		const message = CompletionErrorMapper.miniMaxErrorMessage(response, context);

		return { ok: true, available: false, message, provider: 'minimax', upstreamModel, statusCode: response.status, latencyMs };
	}

	private static async validateOpenAi(model: ModelMappingConfig, upstreamModel: string): Promise<ModelValidationResult> {
		if (!OpenAIOAuthService.getAuthStatus().authenticated) {
			return { ok: true, available: false, message: 'OpenAI is not logged in.', provider: 'openai', upstreamModel };
		}

		const upstreamBody = CompletionModelRouting.buildOpenAiUpstreamBody(probeBody(model.id), model);
		const startTime = Date.now();
		const { response } = await proxyOpenAIRequest(upstreamBody, 'openai');
		const latencyMs = Date.now() - startTime;

		if (response.ok) {
			return {
				ok: true,
				available: true,
				message: 'Model is available.',
				provider: 'openai',
				upstreamModel,
				statusCode: response.status,
				latencyMs
			};
		}

		const message = await CompletionErrorMapper.openAiUpstreamErrorMessage(response);

		return { ok: true, available: false, message, provider: 'openai', upstreamModel, statusCode: response.status, latencyMs };
	}
}
