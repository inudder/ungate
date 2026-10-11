import { eq } from 'drizzle-orm';

import { ModelMappings } from './model-mappings';
import { appSettings } from './schema';

import { getDb } from './index';

import type { AppSettings } from '@ungate/shared';

export class Settings {
	private static generateApiKey(): string {
		return crypto.randomUUID().replace(/-/g, '').slice(0, 15);
	}

	static get(): AppSettings {
		const db = getDb();
		let row = db.select().from(appSettings).where(eq(appSettings.id, 1)).get();
		if (!row) {
			[row] = db
				.insert(appSettings)
				.values({
					id: 1,
					apiKey: this.generateApiKey()
				})
				.returning()
				.all();
		}

		return {
			port: row.port,
			apiKey: row.apiKey,
			quiet: row.quiet,
			extraInstruction: row.extraInstruction,
			models: ModelMappings.list()
		};
	}

	static update(settings: Partial<AppSettings>): void {
		const db = getDb();
		const set: {
			port?: number;
			apiKey?: string | null;
			quiet?: boolean;
			extraInstruction?: string | null;
		} = {};

		if (settings.port !== undefined) set.port = settings.port;
		if (settings.apiKey !== undefined) set.apiKey = settings.apiKey;
		if (settings.quiet !== undefined) set.quiet = settings.quiet;
		if (settings.extraInstruction !== undefined) set.extraInstruction = settings.extraInstruction;

		if (Object.keys(set).length > 0) {
			db.insert(appSettings)
				.values({ id: 1, ...set })
				.onConflictDoUpdate({
					target: appSettings.id,
					set
				})
				.run();
		}

		if (settings.models !== undefined) {
			ModelMappings.replace(settings.models);
		}
	}
}
