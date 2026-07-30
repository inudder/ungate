import { openaiChatErrorMessages } from './error-messages';

interface MiniMaxErrorContext {
	bodyJson?: unknown;
}

export class CompletionErrorMapper {
	private static isClaudeUsageWindowError(status: number, message: string): boolean {
		if (status !== 429) {
			return false;
		}

		return [
			/\busage limit reached\b/i,
			/\busage limit has been reached\b/i,
			/\bclaude pro usage limit\b/i,
			/\byou(?:'ve| have) reached your usage limit\b/i
		].some((pattern) => pattern.test(message));
	}

	static miniMaxErrorMessage(response: Response, context: MiniMaxErrorContext): string {
		return this.miniMaxErrorPayload(response, context).message;
	}

	static miniMaxErrorPayload(response: Response, context: MiniMaxErrorContext): { message: string; code?: string } {
		if (context.bodyJson && typeof context.bodyJson === 'object') {
			const err = (context.bodyJson as { error?: { message?: string; code?: string } }).error;

			if (err?.message) {
				return { message: err.message, ...(err.code && { code: err.code }) };
			}

			return { message: openaiChatErrorMessages.unknownUpstream };
		}

		return { message: `HTTP ${response.status}` };
	}

	static async openAiUpstreamErrorMessage(response: Response): Promise<string> {
		const errBody = await response.json().catch(() => ({ error: { message: `HTTP ${response.status}` } }));
		const err = errBody as { error?: { message?: string } };
		const message = err?.error?.message;

		if (message) {
			return message;
		}

		return openaiChatErrorMessages.unknownUpstream;
	}

	static claudeApiErrorPayload(errorJson: unknown, status = 0): { message: string; type?: string; code?: string } {
		const error = errorJson as { error?: { message?: string; type?: string } };
		let errorMessage = error?.error?.message ?? openaiChatErrorMessages.unknownUpstream;

		if (errorMessage.includes('model:')) {
			errorMessage = errorMessage.replace(/model:\s*x-([^\s,]+)/g, (_match, modelName) => `model: ${modelName}`);
		}

		const payload: { message: string; type?: string; code?: string } = {
			message: errorMessage
		};

		if (this.isClaudeUsageWindowError(status, errorMessage)) {
			payload.message = `Quota exceeded: ${errorMessage}`;
			payload.code = 'insufficient_quota';
		}

		const errType = error?.error?.type;

		if (errType) {
			payload.type = errType;
		}

		return payload;
	}
}
