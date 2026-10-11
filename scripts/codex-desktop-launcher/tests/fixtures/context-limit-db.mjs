import { DatabaseSync } from 'node:sqlite';

const databasePath = process.argv[2];
const limit = Number(process.argv[3]);
const db = new DatabaseSync(databasePath);
db.exec(
	'CREATE TABLE IF NOT EXISTS model_context_overrides (provider TEXT, model_id TEXT, real_context INTEGER, source TEXT, refreshed_at TEXT)'
);
db.exec('CREATE TABLE IF NOT EXISTS model_capability_overrides (provider TEXT, model_id TEXT, override_key TEXT, value INTEGER)');
db.prepare('DELETE FROM model_context_overrides').run();
db.prepare('INSERT INTO model_context_overrides VALUES (?, ?, ?, ?, ?)').run(
	'openai-compatible-chat-abc',
	'mimo-v2.6-pro',
	limit,
	'manual',
	'now'
);
db.prepare('DELETE FROM model_capability_overrides').run();
db.prepare('INSERT INTO model_capability_overrides VALUES (?, ?, ?, ?)').run(
	'openai-compatible-chat-abc',
	'mimo-v2.6-pro',
	'max_output_tokens',
	8192
);
db.close();
