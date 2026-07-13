import { CompletionModelRouting } from 'src/orchestration/openai';

import type { ModelMappingConfig } from '@ungate/shared';

export type ResponsesRouteTarget = 'minimax' | 'openai' | 'claude';

export class ResponsesRouteDecision {
	static decideRoute(resolvedModel: ModelMappingConfig | null, requestedModel: string): ResponsesRouteTarget {
		if (CompletionModelRouting.shouldRouteMiniMax(resolvedModel, requestedModel)) {
			return 'minimax';
		}

		if (CompletionModelRouting.isOpenAiMapped(resolvedModel)) {
			return 'openai';
		}

		return 'claude';
	}
}
