import { openaiToAnthropic } from 'src/adapter/openai-to-anthropic';

import type { ModelMappingConfig } from '@ungate/shared';
import type { OpenAIChatRequest } from 'src/types/openai';

const MINIMAX_ADD_FILE_INSTRUCTION = [
	'For Add File, copy this exact grammar and replace only the path and content:',
	'*** Begin Patch',
	'*** Add File: relative/path',
	'+content',
	'*** End Patch',
	'There must be exactly one ASCII space after the colon. Every content line must start with a literal + in column 1. Do not add @@, indent the +, or escape it.'
].join('\n');

const MINIMAX_UPDATE_FILE_INSTRUCTION = [
	'For Update File, copy this exact grammar and replace only the path and lines:',
	'*** Begin Patch',
	'*** Update File: relative/path',
	'@@',
	' unchanged context',
	'-removed line',
	'+added line',
	'*** End Patch',
	'Every hunk body line must start in column 1 with a space for context, - for deletion, or + for addition. Never emit a raw empty line inside a hunk: preserve an existing blank line as a line containing exactly one ASCII space, add a blank line as a line containing only +, and delete one as a line containing only -.'
].join('\n');

const MINIMAX_FILE_EDITING_INSTRUCTION = [
	'MiniMax tool compatibility: when mcp__ungate_patch__apply_patch appears in the tool list, it is available and must be used for source edits.',
	'Call the MCP patch tool with its exact working_directory, patch, and optional dry_run fields; do not replace it with shell or Python file edits.',
	MINIMAX_ADD_FILE_INSTRUCTION,
	MINIMAX_UPDATE_FILE_INSTRUCTION,
	'If the MCP patch tool is not present in the tool list, use exec_command as the file-editing fallback.',
	'Autonomous execution: research and planning are intermediate work, not task completion. While requested work remains, immediately call the next needed tool in the same turn; do not return a prose-only message that merely promises a future read, edit, or continuation.',
	'For change requests, complete the sequence: inspect the required context, edit through the available patch tool, run relevant checks, then report the result.',
	'Only finish without another tool call when the request is actually complete, a user decision is required, or a concrete blocker prevents safe progress; state that exact blocker.'
].join('\n');

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

function hasMiniMaxPatchTool(body: OpenAIChatRequest): boolean {
	return Boolean(
		body.tools?.some((tool) => {
			const name = tool.function.name;
			const parameters = tool.function.parameters;

			return (
				(name === 'apply_patch' || name === 'mcp__ungate_patch__apply_patch') &&
				parameters !== undefined &&
				typeof parameters === 'object' &&
				!Array.isArray(parameters)
			);
		})
	);
}

function withMiniMaxFileEditingInstruction(body: OpenAIChatRequest): OpenAIChatRequest {
	if (!hasMiniMaxExecCommand(body) && !hasMiniMaxPatchTool(body)) {
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
