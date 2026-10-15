import { describe, expect, it } from 'vitest';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

import { migrate } from 'drizzle-orm/better-sqlite3/migrator';

import { Settings } from 'src/database/app-settings';
import { ModelMappings } from 'src/database/model-mappings';
import { getDb, schema } from 'src/database';

import type { ModelMappingConfig } from '@ungate/shared';

function migrationsFolder(): string {
	const candidates = [join(process.cwd(), 'drizzle'), join(process.cwd(), 'apps', 'api', 'drizzle')];
	const found = candidates.find((candidate) => existsSync(join(candidate, 'meta', '_journal.json')));

	if (!found) {
		throw new Error(`Drizzle migrations folder not found from ${process.cwd()}`);
	}

	return found;
}

function model(id: string, sortOrder: number): ModelMappingConfig {
	return {
		id,
		label: id,
		provider: 'claude',
		upstreamModel: id,
		sortOrder,
		reasoningBudget: null,
		contextWindow: null,
		maxOutputTokens: null
	};
}

describe('database-app-settings', () => {
	it('creates defaults when row is missing', () => {
		const expectedModels = [
			{
				id: 'test-default-model',
				label: 'Test Default Model',
				provider: 'claude' as const,
				upstreamModel: 'claude-test-default-model',
				sortOrder: 0,
				reasoningBudget: null,
				contextWindow: null,
				maxOutputTokens: null
			}
		];
		ModelMappings.replace(expectedModels);
		const settings = Settings.get();

		expect(settings.port).toBe(47821);
		expect(settings.apiKey).toBeTypeOf('string');
		expect(settings.models).toEqual(expectedModels);
	});

	it('updates subset of fields and model mappings', () => {
		Settings.get();
		const model = {
			id: 'm',
			label: 'M',
			provider: 'claude' as const,
			upstreamModel: 'u',
			sortOrder: 0,
			reasoningBudget: null,
			contextWindow: 400000,
			maxOutputTokens: 128000
		};

		Settings.update({
			quiet: true,
			extraInstruction: 'extra',
			models: [model]
		});

		const settings = Settings.get();
		expect(settings.quiet).toBe(true);
		expect(settings.extraInstruction).toBe('extra');
		expect(settings.models).toEqual([model]);
	});

	it('replaces models when the update has no app setting fields', () => {
		const kept = model('claude-sonnet-5-5', 0);
		const removed = model('claude-opus-4-8', 1);

		Settings.update({ models: [kept, removed] });
		Settings.update({ models: [kept] });

		expect(Settings.get().models).toEqual([kept]);
	});

	it('does not restore deleted models when startup migrations run again', () => {
		const kept = model('claude-haiku-5-5', 0);
		const removed = model('claude-opus-4-8', 1);

		Settings.update({ models: [kept, removed] });
		Settings.update({ models: [kept] });
		migrate(getDb(), { migrationsFolder: migrationsFolder() });

		expect(Settings.get().models).toEqual([kept]);
		expect(ModelMappings.list().map((item) => item.id)).toEqual(['claude-haiku-5-5']);
	});
});
