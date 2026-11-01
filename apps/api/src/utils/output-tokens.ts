import { isModelTokenLimit } from '@ungate/shared';

/**
 * Minimum output budget used when the client omits a limit and the model mapping has no cap.
 * Reasoning models exhaust a smaller hardcoded budget on hidden thinking before they emit any
 * visible content, which ends the turn with an empty `max_output_tokens` incomplete response.
 */
export const COMPLETION_TOKEN_FLOOR = 8192;

/**
 * Picks the output token cap sent upstream: the client's value clamped to the model's
 * configured cap, else the model's cap, else the provider fallback.
 */
export function resolveMaxOutputTokens(
	requested: number | undefined,
	modelCap: number | null | undefined,
	fallback: number
): number {
	const cap = isModelTokenLimit(modelCap) ? modelCap : undefined;

	if (requested !== undefined && Number.isFinite(requested) && requested > 0) {
		const value = Math.floor(requested);

		return cap === undefined ? value : Math.min(value, cap);
	}

	return cap ?? fallback;
}
