import { integer, real, sqliteTable, text } from 'drizzle-orm/sqlite-core';

export const appSettings = sqliteTable('app_settings', {
	id: integer()
		.primaryKey({ autoIncrement: false })
		.$defaultFn(() => 1),
	port: integer().notNull().default(47821),
	apiKey: text(),
	quiet: integer({ mode: 'boolean' }).notNull().default(false),
	extraInstruction: text()
});

export const providerSettings = sqliteTable('provider_settings', {
	provider: text().primaryKey(),
	accessToken: text().notNull(),
	refreshToken: text(),
	expiresAt: integer(),
	email: text(),
	accountId: text(),
	createdAt: integer().notNull(),
	baseUrl: text(),
	credentialVersion: text().notNull().default(''),
	authState: text().notNull().default('ready'),
	authErrorCode: text(),
	lastRefreshAt: integer(),
	nextRetryAt: integer(),
	refreshFailures: integer().notNull().default(0)
});

export const modelMappings = sqliteTable('model_mappings', {
	id: text().primaryKey(),
	label: text().notNull(),
	provider: text().notNull(),
	upstreamModel: text().notNull(),
	sortOrder: integer().notNull().default(0),
	reasoningBudget: text(),
	contextWindow: integer(),
	maxOutputTokens: integer()
});

export const requests = sqliteTable('requests', {
	id: integer().primaryKey({ autoIncrement: true }),
	timestamp: integer().notNull(),
	model: text().notNull(),
	source: text().notNull(),
	inputTokens: integer().notNull().default(0),
	outputTokens: integer().notNull().default(0),
	cacheReadTokens: integer().notNull().default(0),
	cacheCreationTokens: integer().notNull().default(0),
	reasoningTokens: integer(),
	estimatedCost: real().notNull().default(0),
	stream: integer({ mode: 'boolean' }).notNull().default(false),
	latencyMs: integer(),
	error: text()
});

export const schema = { appSettings, requests, providerSettings, modelMappings };
