<script lang="ts">
import IconLoader from 'virtual:icons/lucide/loader-circle';
import IconSend from 'virtual:icons/lucide/send';

import { Api } from '$shared/api';

import type { WakePingStatus } from '$shared/api';

let status = $state<WakePingStatus | null>(null);
let workStart = $state('07:00');
let workEnd = $state('22:00');
let loading = $state(true);
let saving = $state(false);
let sending = $state(false);
let error = $state<string | null>(null);

$effect(() => {
	void load();
});

function formatDate(value: string | null): string {
	if (!value) return 'never';

	return new Date(value).toLocaleString();
}

async function load(): Promise<void> {
	loading = true;
	error = null;

	try {
		status = await Api.wakePingStatus();
		workStart = status.workStart;
		workEnd = status.workEnd;
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
	} finally {
		loading = false;
	}
}

async function setEnabled(event: Event): Promise<void> {
	const enabled = (event.currentTarget as HTMLInputElement).checked;
	saving = true;
	error = null;

	try {
		await Api.updateWakePing({ enabled });
		await load();
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
	} finally {
		saving = false;
	}
}

async function saveSchedule(): Promise<void> {
	if (workStart >= workEnd) {
		error = 'Active from must be earlier than active until.';

		return;
	}

	saving = true;
	error = null;

	try {
		await Api.updateWakePing({ workStart, workEnd });
		await load();
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
	} finally {
		saving = false;
	}
}

async function sendNow(): Promise<void> {
	sending = true;
	error = null;

	try {
		const result = await Api.sendWakePing();
		if (result.lastPingError) {
			throw new Error(result.lastPingError);
		}

		await load();
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
	} finally {
		sending = false;
	}
}
</script>

<div class="card preset-tonal-surface border border-surface-700/30 p-5 space-y-4">
	<div class="flex items-center justify-between">
		<div>
			<p class="text-sm font-semibold">Wake Ping</p>
			<p class="text-xs text-surface-400">Keeps the Claude quota window active during working hours.</p>
		</div>
		{#if loading}
			<IconLoader class="size-4 animate-spin text-surface-400" />
		{/if}
	</div>

	{#if status}
		<label class="flex items-center gap-3 cursor-pointer">
			<input
				class="checkbox"
				type="checkbox"
				checked={status.enabled}
				disabled={saving}
				onchange={(event) => void setEnabled(event)} />
			<span class="text-sm">Enable scheduled wake pings</span>
		</label>

		<div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
			<label class="label">
				<span class="label-text text-xs">Active from</span>
				<input
					class="input text-sm"
					type="time"
					bind:value={workStart}
					disabled={saving}
					onchange={() => void saveSchedule()} />
			</label>
			<label class="label">
				<span class="label-text text-xs">Active until</span>
				<input
					class="input text-sm"
					type="time"
					bind:value={workEnd}
					disabled={saving}
					onchange={() => void saveSchedule()} />
			</label>
		</div>

		<div class="grid grid-cols-1 sm:grid-cols-3 gap-2 text-xs text-surface-400">
			<p>Scheduler: {status.running ? 'running' : 'stopped'}</p>
			<p>Next: {formatDate(status.nextPingAt)}</p>
			<p>Last: {formatDate(status.lastPingAt)}</p>
		</div>

		<button
			class="btn btn-sm preset-tonal-surface"
			type="button"
			disabled={sending}
			onclick={() => void sendNow()}>
			{#if sending}
				<IconLoader class="size-4 animate-spin" />
				Sending...
			{:else}
				<IconSend class="size-4" />
				Send now
			{/if}
		</button>

		{#if status.lastPingError}
			<p class="text-xs text-error-500">{status.lastPingError}</p>
		{/if}
	{/if}

	{#if error}
		<div class="card preset-tonal-error p-3 text-sm">{error}</div>
	{/if}
</div>
