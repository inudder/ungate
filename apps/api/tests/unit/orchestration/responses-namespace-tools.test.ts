import { describe, expect, it } from 'vitest';

import { flattenResponsesNamespaceTools, restoreResponsesNamespaceValue } from 'src/orchestration/responses';

import type { OpenAIResponsesRequest } from 'src/types/openai';

function namespaceRequest(): OpenAIResponsesRequest {
	return {
		model: 'miniMax-M3',
		input: [
			{
				type: 'function_call',
				call_id: 'call_patch',
				name: 'apply_patch',
				namespace: 'mcp__ungate_patch',
				arguments: '{"dry_run":true}'
			}
		],
		tools: [
			{
				type: 'namespace',
				name: 'mcp__ungate_patch',
				tools: [
					{
						type: 'function',
						name: 'apply_patch',
						description: 'Apply a source patch',
						inputSchema: {
							type: 'object',
							properties: { patch: { type: 'string' }, dry_run: { type: 'boolean' } },
							required: ['patch']
						}
					}
				]
			}
		],
		tool_choice: { type: 'function', name: 'apply_patch', namespace: 'mcp__ungate_patch' }
	};
}

describe('Responses namespace tools', () => {
	it('flattens namespace tools, history, schemas, and tool choice', () => {
		const { request, mapping } = flattenResponsesNamespaceTools(namespaceRequest());

		expect(request.tools).toEqual([
			{
				type: 'function',
				name: 'mcp__ungate_patch__apply_patch',
				description: 'Apply a source patch',
				parameters: {
					type: 'object',
					properties: { patch: { type: 'string' }, dry_run: { type: 'boolean' } },
					required: ['patch']
				},
				strict: undefined
			}
		]);
		expect(request.input).toEqual([
			{
				type: 'function_call',
				call_id: 'call_patch',
				name: 'mcp__ungate_patch__apply_patch',
				arguments: '{"dry_run":true}'
			}
		]);
		expect(request.tool_choice).toEqual({ type: 'function', name: 'mcp__ungate_patch__apply_patch' });
		expect(mapping.fullToOriginal.get('mcp__ungate_patch__apply_patch')).toEqual({
			namespace: 'mcp__ungate_patch',
			name: 'apply_patch'
		});
	});

	it('restores namespace metadata on nested Responses function-call items', () => {
		const { mapping } = flattenResponsesNamespaceTools(namespaceRequest());
		const restored = restoreResponsesNamespaceValue(
			{
				type: 'response.output_item.done',
				item: {
					type: 'function_call',
					name: 'mcp__ungate_patch__apply_patch',
					arguments: '{"dry_run":true}'
				}
			},
			mapping
		);

		expect(restored.item).toEqual({
			type: 'function_call',
			name: 'apply_patch',
			arguments: '{"dry_run":true}',
			namespace: 'mcp__ungate_patch'
		});
	});

	it('rejects names that collide after namespace flattening', () => {
		const request = namespaceRequest();
		request.tools?.push({
			type: 'function',
			name: 'mcp__ungate_patch__apply_patch',
			parameters: { type: 'object' }
		});

		expect(() => flattenResponsesNamespaceTools(request)).toThrow('collides with another tool');
	});
});
