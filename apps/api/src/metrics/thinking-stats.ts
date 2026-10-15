import { logger } from 'src/utils/logger';

import type { AnthropicRequest } from 'src/types';
import type { OpenAIChatRequest } from 'src/types/openai';

/**
 * Counts thinking output without keeping its text: the request log reports how
 * much the model reasoned, never what it reasoned about.
 */
export class ThinkingStats {
	blocks = 0;
	chars = 0;
	redactedBlocks = 0;
	private inBlock = false;

	constructor(readonly effort?: string) {}

	/** One Anthropic content block (`thinking` / `redacted_thinking`), from a response body or `content_block_start`. */
	observeAnthropicBlock(block: unknown): void {
		const { type, thinking } = (block ?? {}) as { type?: unknown; thinking?: unknown };

		if (type === 'thinking') {
			this.blocks++;
			if (typeof thinking === 'string') this.chars += thinking.length;
		} else if (type === 'redacted_thinking') {
			this.redactedBlocks++;
		}
	}

	/** Anthropic SSE event: counts block starts and `thinking_delta` text. */
	observeAnthropicEvent(event: unknown): void {
		const { type, content_block, delta } = (event ?? {}) as {
			type?: unknown;
			content_block?: unknown;
			delta?: { type?: unknown; thinking?: unknown };
		};

		if (type === 'content_block_start') {
			this.observeAnthropicBlock(content_block);
		} else if (type === 'content_block_delta' && delta?.type === 'thinking_delta' && typeof delta.thinking === 'string') {
			this.chars += delta.thinking.length;
		}
	}

	/** Reasoning text that arrives as a delta (`reasoning_content`, MiniMax `<think>`); a run of deltas is one block. */
	reasoningDelta(text: string): void {
		if (!text) return;
		if (!this.inBlock) {
			this.blocks++;
			this.inBlock = true;
		}
		this.chars += text.length;
	}

	/** Visible output arrived, so the next reasoning delta starts a new block. */
	endReasoning(): void {
		this.inBlock = false;
	}

	hasOutput(): boolean {
		return this.blocks > 0 || this.redactedBlocks > 0;
	}
}

export function anthropicThinkingEffort(body: AnthropicRequest): string | undefined {
	if (body.thinking?.type === 'disabled') return 'none';
	if (body.output_config?.effort) return body.output_config.effort;
	if (typeof body.reasoning_budget === 'string') return body.reasoning_budget;
	if (body.thinking?.budget_tokens !== undefined) return `budget:${body.thinking.budget_tokens}`;

	return body.thinking?.type;
}

export function chatThinkingEffort(body: OpenAIChatRequest): string | undefined {
	return body.reasoning?.effort ?? body.reasoning_effort ?? undefined;
}

/** Logs one `[Thinking]` line when the request asked for reasoning or the response contained any. */
export function logThinkingSummary(model: string, thinking: ThinkingStats | undefined, reasoningTokens?: number | null): void {
	const tokens = reasoningTokens ?? undefined;
	const requested = thinking?.effort !== undefined && thinking.effort !== 'none';

	if (!requested && !thinking?.hasOutput() && !tokens) return;

	const parts = [
		`model=${model}`,
		`effort=${thinking?.effort ?? 'default'}`,
		`blocks=${thinking?.blocks ?? 0}`,
		`chars=${thinking?.chars ?? 0}`
	];

	if (thinking?.redactedBlocks) parts.push(`redacted=${thinking.redactedBlocks}`);
	parts.push(`reasoning_tokens=${tokens ?? 'n/a'}`);

	logger.log(`[Thinking] ${parts.join(' ')}`);
}
