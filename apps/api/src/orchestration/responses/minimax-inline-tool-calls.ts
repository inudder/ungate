/**
 * MiniMax M3 sometimes emits its internal tool-call protocol as plain assistant
 * text instead of structured `tool_calls` deltas. The upstream then stops with
 * `finish_reason: "stop"`, so Codex sees a prose-only turn, ends the task, and
 * the user has to type "continue". This module recovers those leaked calls and
 * converts them back into real function calls.
 */

const SEGMENT_MARKER = ']<]minimax[>[';
const TOOL_CALL_OPEN = '<tool_call>';
const TOOL_CALL_CLOSE = '</tool_call>';

export interface MiniMaxInlineToolCall {
	name: string;
	arguments: string;
}

export interface MiniMaxInlineExtraction {
	text: string;
	toolCalls: MiniMaxInlineToolCall[];
}

/** Longest suffix of `text` that could still grow into a leaked-call opener. */
export function inlineToolCallPendingSuffix(text: string): string {
	const candidates = [SEGMENT_MARKER, TOOL_CALL_OPEN];
	const maxLength = Math.max(SEGMENT_MARKER.length, TOOL_CALL_OPEN.length);

	for (let length = Math.min(text.length, maxLength - 1); length > 0; length--) {
		const suffix = text.slice(-length);
		if (candidates.some((candidate) => candidate.startsWith(suffix))) {
			return suffix;
		}
	}

	return '';
}

function stripMarkers(value: string): string {
	return value.split(SEGMENT_MARKER).join('');
}

function parseInvokeBlock(block: string): MiniMaxInlineToolCall | null {
	const cleaned = stripMarkers(block);
	const nameMatch = /<invoke\s+name\s*=\s*"([^"]+)"\s*>/u.exec(cleaned);

	if (!nameMatch) {
		return null;
	}

	const body = cleaned.slice(nameMatch.index + nameMatch[0].length);
	const parameters: Record<string, string> = {};
	const parameterPattern = /<(?:parameter\s+name\s*=\s*"([^"]+)"|([a-zA-Z_][\w-]*))\s*>([\s\S]*?)<\/(?:parameter|\2)>/gu;
	let match = parameterPattern.exec(body);

	while (match) {
		const key = match[1] ?? match[2];
		if (key && key !== 'invoke') {
			parameters[key] = match[3];
		}
		match = parameterPattern.exec(body);
	}

	if (Object.keys(parameters).length === 0) {
		return null;
	}

	return { name: nameMatch[1], arguments: JSON.stringify(parameters) };
}

function parseJsonBlock(block: string): MiniMaxInlineToolCall | null {
	const cleaned = stripMarkers(block).trim();

	if (!cleaned.startsWith('{')) {
		return null;
	}

	try {
		const parsed: unknown = JSON.parse(cleaned);
		if (!parsed || typeof parsed !== 'object') {
			return null;
		}

		const record = parsed as Record<string, unknown>;
		const name = record.name ?? record.tool ?? record.function;
		if (typeof name !== 'string' || !name.trim()) {
			return null;
		}

		const rawArguments = record.arguments ?? record.parameters ?? record.input ?? {};

		return {
			name,
			arguments: typeof rawArguments === 'string' ? rawArguments : JSON.stringify(rawArguments)
		};
	} catch {
		return null;
	}
}

function parseToolCallBlock(block: string): MiniMaxInlineToolCall | null {
	return parseInvokeBlock(block) ?? parseJsonBlock(block);
}

/**
 * Splits assistant text into user-visible prose plus any tool calls that leaked
 * into it. Unparseable blocks are dropped rather than shown to the user: they
 * are protocol noise, never intended output.
 */
export function extractMiniMaxInlineToolCalls(text: string): MiniMaxInlineExtraction {
	if (!text.includes(TOOL_CALL_OPEN) && !text.includes(SEGMENT_MARKER)) {
		return { text, toolCalls: [] };
	}

	const toolCalls: MiniMaxInlineToolCall[] = [];
	let visible = '';
	let rest = text;

	while (rest.length > 0) {
		const openIndex = rest.indexOf(TOOL_CALL_OPEN);

		if (openIndex === -1) {
			visible += rest;
			break;
		}

		visible += rest.slice(0, openIndex);
		const afterOpen = rest.slice(openIndex + TOOL_CALL_OPEN.length);
		const closeIndex = afterOpen.indexOf(TOOL_CALL_CLOSE);
		const block = closeIndex === -1 ? afterOpen : afterOpen.slice(0, closeIndex);
		const parsed = parseToolCallBlock(block);

		if (parsed) {
			toolCalls.push(parsed);
		}

		rest = closeIndex === -1 ? '' : afterOpen.slice(closeIndex + TOOL_CALL_CLOSE.length);
	}

	return { text: stripMarkers(visible).trimEnd(), toolCalls };
}
