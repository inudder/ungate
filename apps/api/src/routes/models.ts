import { z } from 'zod';

import { isModelMappingProvider, isReasoningBudgetTier, type ModelMappingConfig } from '@ungate/shared';

import { Settings } from '../database/app-settings';
import { ModelValidator } from '../services/model-validator';

import type { FastifyPluginCallback } from 'fastify';

const ModelValidateSchema = z.object({
	model: z.object({
		id: z.string(),
		label: z.string(),
		provider: z.string().refine((value) => isModelMappingProvider(value), {
			message: 'Model provider must be claude, openai or minimax'
		}),
		upstreamModel: z.string(),
		sortOrder: z.number().int(),
		reasoningBudget: z.union([
			z.null(),
			z.string().refine((value) => isReasoningBudgetTier(value), { message: 'Invalid reasoningBudget' })
		])
	})
});

const plugin: FastifyPluginCallback = (app) => {
	app.get('/v1/models', async (_request, reply) => {
		const settings = Settings.get();
		const data = settings.models.map((model) => ({
			id: model.id,
			object: 'model' as const,
			created: 1700000000,
			owned_by: model.provider
		}));

		return reply.send({
			object: 'list',
			data
		});
	});

	app.post('/models/validate', async (request, reply) => {
		const result = ModelValidateSchema.safeParse(request.body);

		if (!result.success) {
			const issue = result.error.issues[0];
			const path = issue.path.length ? ` at ${issue.path.join('.')}` : '';

			return reply.code(400).send({ ok: false, error: `${issue.message}${path}` });
		}

		const validation = await ModelValidator.validate(result.data.model as ModelMappingConfig);

		return reply.send(validation);
	});
};

export default plugin;
