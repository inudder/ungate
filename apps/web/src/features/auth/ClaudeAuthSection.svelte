<script lang="ts">
import { onMount } from 'svelte';
import IconAlertTriangle from 'virtual:icons/lucide/alert-triangle';
import IconCheck from 'virtual:icons/lucide/check';
import IconExternalLink from 'virtual:icons/lucide/external-link';
import IconLoader from 'virtual:icons/lucide/loader-circle';
import IconLogOut from 'virtual:icons/lucide/log-out';

import { Api } from '$shared/api';

import { getSettingsUiStore } from '../settings/settings-ui-store.svelte';

import type { ClaudeAuthStatus } from '@ungate/shared/frontend';

type Phase = 'idle' | 'pending-code' | 'completing';

interface Props {
	onAuthStatusChange?: () => void;
}

let { onAuthStatusChange }: Props = $props();

const uiStore = getSettingsUiStore();
let status = $derived(uiStore.claudeStatus);
let refreshing = $state(false);
let authenticated = $derived(status.authenticated);
let sessionExpired = $derived(status.sessionExpired ?? false);
let email = $derived(status.email);
let loading = $state(true);
let phase = $state<Phase>('idle');
let authUrl = $state('');
let sessionId = $state('');
let codeInput = $state('');
let error = $state<string | null>(null);

onMount(() => {
	void loadStatus();
});

function applyStatus(value: ClaudeAuthStatus): void {
	uiStore.applyClaudeStatus(value);
}

async function handleRefresh(): Promise<void> {
	refreshing = true;
	error = null;
	try {
		applyStatus(await Api.authRefresh());
	} catch (e) {
		error = e instanceof Error ? e.message : String(e);
	} finally {
		refreshing = false;
	}
}

function authErrorMessage(code: string): string {
	if (code === 'proxy_unavailable') return 'The Claude proxy is unavailable. Check that GOST is running.';
	if (code === 'rate_limited') return 'Claude asked us to wait before the next token update.';
	if (code === 'upstream_forbidden') return 'Claude rejected the connection. The saved authorization will be retried.';

	return 'The token update could not finish. We will try again automatically.';
}

function formatTime(value: number | undefined): string {
	return value ? new Date(value).toLocaleString() : 'Not yet';
}

async function loadStatus(showLoading = true) {
	if (showLoading) loading = true;
	error = null;

	try {
		applyStatus(await Api.authStatus());
	} catch (e) {
		error = e instanceof Error ? e.message : String(e);
	}

	loading = false;
}

async function handleStartLogin() {
	error = null;

	try {
		const result = await Api.authStart();
		authUrl = result.authUrl;
		sessionId = result.sessionId;
		phase = 'pending-code';
		window.open(authUrl, '_blank', 'noopener,noreferrer');
	} catch (e) {
		error = e instanceof Error ? e.message : String(e);
	}
}

async function handleComplete() {
	error = null;
	phase = 'completing';

	const code = codeInput.trim();

	try {
		const result = await Api.authComplete(code, sessionId);

		if (!result.ok) {
			error = result.error ?? 'Login failed';
			phase = 'pending-code';

			return;
		}

		await loadStatus(false);
		phase = 'idle';
		codeInput = '';
		authUrl = '';
		sessionId = '';
		onAuthStatusChange?.();
	} catch (e) {
		error = e instanceof Error ? e.message : String(e);
		phase = 'pending-code';
	}
}

async function handleLogout() {
	error = null;

	try {
		await Api.authLogout();
		applyStatus({ authenticated: false, state: 'disconnected' });
		phase = 'idle';
		onAuthStatusChange?.();
	} catch (e) {
		error = e instanceof Error ? e.message : String(e);
	}
}

function handleCancelLogin() {
	phase = 'idle';
	authUrl = '';
	sessionId = '';
	codeInput = '';
	error = null;
}
</script>

<div class="card preset-tonal-surface border border-surface-700/30 p-5 space-y-4">
	<p class="text-sm font-semibold">Claude</p>

	{#if loading}
		<div class="flex items-center gap-2 text-sm text-surface-400">
			<IconLoader class="size-4 animate-spin" />
			Checking status...
		</div>
	{:else if phase === 'pending-code' || phase === 'completing'}
		<div class="space-y-3">
			<div class="flex items-center gap-2 text-sm text-surface-400">
				<a
					href={authUrl}
					target="_blank"
					rel="noopener noreferrer"
					class="anchor flex items-center gap-1">
					<IconExternalLink class="size-3.5" />
					Open authorization page
				</a>
				<span>— paste the code below</span>
			</div>
			<input
				class="input text-sm font-mono"
				type="text"
				bind:value={codeInput}
				placeholder="CODE#STATE" />
			<div class="flex gap-2">
				<button
					class="btn btn-sm preset-filled-primary-500"
					onclick={handleComplete}
					disabled={phase === 'completing' || !codeInput.trim()}>
					{#if phase === 'completing'}
						<IconLoader class="size-4 animate-spin" />
						Verifying...
					{:else}
						Confirm
					{/if}
				</button>
				<button
					class="btn btn-sm preset-outlined-surface-700 hover:preset-filled-surface-500"
					onclick={handleCancelLogin}
					disabled={phase === 'completing'}>
					Cancel
				</button>
			</div>
		</div>
	{:else if status.state === 'retry_wait' || status.state === 'refreshing'}
		<div class="space-y-3 text-sm">
			<p class="text-warning-400"
				>{status.state === 'refreshing'
					? 'Refreshing Claude authorization...'
					: 'Claude connection is temporarily unavailable. Your authorization is saved.'}</p>
			{#if status.errorCode}<p class="text-xs text-surface-400">{authErrorMessage(status.errorCode)}</p>{/if}
			{#if status.nextRetryAt}<p class="text-xs text-surface-400">Next attempt: {formatTime(status.nextRetryAt)}</p>{/if}
			<button
				class="btn btn-sm preset-filled-primary-500"
				onclick={handleRefresh}
				disabled={refreshing || status.state === 'refreshing'}>{refreshing ? 'Retrying...' : 'Retry now'}</button>
			<button
				class="btn btn-sm preset-filled-surface-500"
				onclick={handleLogout}>Logout</button>
		</div>
	{:else if sessionExpired}
		<div class="space-y-3">
			<div class="flex items-center gap-2 text-sm text-warning-400">
				<IconAlertTriangle class="size-4" />
				<span>Authorization required{email ? ` for ${email}` : ''}</span>
			</div>
			{#if status.errorCode === 'refresh_uncertain'}
				<p class="text-xs text-surface-400"
					>The refresh result is unknown. Re-authorize to recover; the previous refresh token will not be replayed.</p>
			{/if}
			<div class="flex items-center gap-2">
				<button
					class="btn btn-sm preset-filled-primary-500"
					onclick={handleStartLogin}>
					Re-authorize
				</button>
				<button
					class="btn btn-sm preset-filled-surface-500 border border-surface-500/50 hover:preset-filled-surface-400 w-fit"
					onclick={handleLogout}>
					<IconLogOut class="size-4" />
					Logout
				</button>
			</div>
		</div>
	{:else if authenticated}
		<div class="space-y-3">
			<div class="flex items-center gap-2 text-sm">
				<IconCheck class="size-4 text-success-500" />
				<span>Logged in{email ? ` as ${email}` : ''}</span>
			</div>
			<div class="flex items-center gap-2">
				<button
					class="btn btn-sm preset-outlined-surface-700 hover:preset-filled-surface-500"
					onclick={handleStartLogin}>
					Re-authorize
				</button>
				<button
					class="btn btn-sm preset-filled-surface-500 border border-surface-500/50 hover:preset-filled-surface-400 w-fit"
					onclick={handleLogout}>
					<IconLogOut class="size-4" />
					Logout
				</button>
			</div>
		</div>
	{:else if phase === 'idle'}
		<p class="text-sm text-surface-400">Not logged in.</p>
		<button
			class="btn btn-sm preset-filled-primary-500"
			onclick={handleStartLogin}>
			Login with Claude
		</button>
	{/if}

	{#if status.lastRefreshAt}
		<p class="text-xs text-surface-400">Last token update: {formatTime(status.lastRefreshAt)}</p>
	{/if}

	{#if error}
		<div class="card preset-tonal-error p-3 text-sm">
			{error}
		</div>
	{/if}
</div>
