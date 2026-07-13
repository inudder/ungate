import { openaiToAnthropic } from 'src/adapter/openai-to-anthropic';

import type { ModelMappingConfig } from '@ungate/shared';
import type { OpenAIChatRequest } from 'src/types/openai';

const MINIMAX_FILE_EDITING_INSTRUCTION = [
	'MiniMax tool compatibility: the apply_patch custom tool is unavailable for this provider.',
	'When a local file must be changed and exec_command is available, you must use exec_command to perform the edit.',
	'PowerShell and Python file-editing commands are permitted for this MiniMax session; this rule overrides earlier instructions requiring apply_patch or prohibiting shell/Python writes.',
	'Autonomous execution: research and planning are intermediate work, not task completion. While requested work remains, immediately call the next needed tool in the same turn; do not return a prose-only message that merely promises a future read, edit, or continuation.',
	'For change requests, complete the sequence: inspect the required context, edit through exec_command, run relevant checks, then report the result.',
	'Only finish without another tool call when the request is actually complete, a user decision is required, or a concrete blocker prevents safe progress; state that exact blocker.'
].join(' ');

function hasMiniMaxExecCommand(body: OpenAIChatRequest): boolean {
	return Boolean(
		body.tools?.some((tool) => {
			const parameters = tool.function.parameters;

			return (
				tool.function.name === 'exec_command' &&
				parameters !== undefined &&
				typeof parameters === 'object' &&
				!Array.isArray(parameters)
			);
		})
	);
}

function withMiniMaxFileEditingInstruction(body: OpenAIChatRequest): OpenAIChatRequest {
	if (!hasMiniMaxExecCommand(body)) {
		return body;
	}

	let insertionIndex = 0;

	while (body.messages[insertionIndex]?.role === 'system' || body.messages[insertionIndex]?.role === 'developer') {
		insertionIndex += 1;
	}

	return {
		...body,
		messages: [
			...body.messages.slice(0, insertionIndex),
			{ role: 'system', content: MINIMAX_FILE_EDITING_INSTRUCTION },
			...body.messages.slice(insertionIndex)
		]
	};
}

export class CompletionModelRouting {
	static isMiniMaxModel(model: string): boolean {
		const normalized = model.trim().toLowerCase();

		if (normalized.startsWith('minimax')) {
			return true;
		}

		if (normalized.startsWith('mini-max')) {
			return true;
		}

		return false;
	}

	static shouldRouteMiniMax(resolved: ModelMappingConfig | null, requestedModel: string): boolean {
		if (resolved?.provider === 'minimax') {
			return true;
		}

		return CompletionModelRouting.isMiniMaxModel(requestedModel);
	}

	static buildMiniMaxBody(openaiBody: OpenAIChatRequest, resolved: ModelMappingConfig | null): OpenAIChatRequest {
		const withModel = resolved?.provider === 'minimax' ? { ...openaiBody, model: resolved.upstreamModel } : openaiBody;
		const hasClientReasoning = Boolean(withModel.reasoning?.effort ?? withModel.reasoning_effort);

		const withReasoning: OpenAIChatRequest =
			!hasClientReasoning && resolved?.reasoningBudget
				? { ...withModel, reasoning: { effort: resolved.reasoningBudget } }
				: withModel;

		return withMiniMaxFileEditingInstruction(withReasoning);
	}

	static isOpenAiMapped(resolved: ModelMappingConfig | null): resolved is ModelMappingConfig {
		if (!resolved) {
			return false;
		}

		if (String(resolved.provider) !== 'openai') {
			return false;
		}

		return true;
	}

	static buildOpenAiUpstreamBody(openaiBody: OpenAIChatRequest, resolved: ModelMappingConfig): OpenAIChatRequest {
		const withModel: OpenAIChatRequest = {
			...openaiBody,
			model: resolved.upstreamModel
		};

		if (resolved.reasoningBudget) {
			const withReasoning: OpenAIChatRequest = {
				...withModel,
				reasoning: { effort: resolved.reasoningBudget }
			};

			return withReasoning;
		}

		return withModel;
	}

	static toAnthropicRequest(
		openaiBody: OpenAIChatRequest,
		resolved: ModelMappingConfig | null
	): ReturnType<typeof openaiToAnthropic> {
		if (resolved?.provider === 'claude') {
			return openaiToAnthropic(openaiBody, {
				model: resolved.upstreamModel,
				reasoningBudget: resolved.reasoningBudget
			});
		}

		return openaiToAnthropic(openaiBody);
	}
}
