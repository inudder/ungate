-- Migration 0010: reasoning tokens per request (null when the provider does not report them)
ALTER TABLE requests ADD COLUMN reasoning_tokens integer;
