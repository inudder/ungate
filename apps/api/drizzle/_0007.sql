-- Migration 0007: persist Anthropic prompt-cache usage.
ALTER TABLE `requests` ADD `cache_read_tokens` integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE `requests` ADD `cache_creation_tokens` integer DEFAULT 0 NOT NULL;
