-- Migration 0009: per-model context window and output token cap
ALTER TABLE model_mappings ADD COLUMN context_window integer;
--> statement-breakpoint
ALTER TABLE model_mappings ADD COLUMN max_output_tokens integer;
--> statement-breakpoint
UPDATE model_mappings SET context_window = 1000000, max_output_tokens = 128000
WHERE provider = 'claude' AND upstream_model IN (
	'claude-opus-4-6', 'claude-opus-4-7', 'claude-opus-4-8', 'claude-opus-5', 'claude-opus-5-5',
	'claude-sonnet-4-6', 'claude-sonnet-5', 'claude-sonnet-5-5', 'claude-haiku-5-5',
	'claude-fable-5', 'claude-fable-5-1'
);
--> statement-breakpoint
UPDATE model_mappings SET context_window = 200000, max_output_tokens = 64000
WHERE provider = 'claude' AND upstream_model IN ('claude-haiku-4-5', 'claude-haiku-4-5-20251001');
