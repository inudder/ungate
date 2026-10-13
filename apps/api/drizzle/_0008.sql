ALTER TABLE provider_settings ADD COLUMN credential_version text NOT NULL DEFAULT '';
--> statement-breakpoint
ALTER TABLE provider_settings ADD COLUMN auth_state text NOT NULL DEFAULT 'ready';
--> statement-breakpoint
ALTER TABLE provider_settings ADD COLUMN auth_error_code text;
--> statement-breakpoint
ALTER TABLE provider_settings ADD COLUMN last_refresh_at integer;
--> statement-breakpoint
ALTER TABLE provider_settings ADD COLUMN next_retry_at integer;
--> statement-breakpoint
ALTER TABLE provider_settings ADD COLUMN refresh_failures integer NOT NULL DEFAULT 0;
--> statement-breakpoint
UPDATE provider_settings SET credential_version = lower(hex(randomblob(16))),
    auth_state = CASE WHEN access_token = '' AND refresh_token IS NULL THEN 'reauth_required' ELSE 'ready' END
WHERE provider = 'claude';
