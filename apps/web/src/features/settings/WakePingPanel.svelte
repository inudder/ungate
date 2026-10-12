<script lang="ts">
import IconLoader from 'virtual:icons/lucide/loader-circle';
import IconSend from 'virtual:icons/lucide/send';

import { Api } from '$shared/api';

import type { ProviderModelCatalogItem } from '@ungate/shared/frontend';
import type { WakePingStatus } from '$shared/api';

let status = $state<WakePingStatus | null>(null);
let workStart = $state('07:00');
let workEnd = $state('22:00');
let model = $state('');
let catalog = $state<ProviderModelCatalogItem[]>([]);
let catalogLoaded = $state(false);
let catalogError = $state<string | null>(null);
let loading = $state(true);
let saving = $state(false);
let sending = $state(false);
let error = $state<string | null>(null);

const modelUnavailable = $derived(
	Boolean(status && catalogLoaded && !catalogError && !catalog.some((item) => item.upstreamModel === status?.model))
);

$effect(() => {
	void load();

	const onVisible = (): void => {
		if (document.visibilityState === 'visible' && !saving && !sending) void load({ silent: true });
	};
	document.addEventListener('visibilitychange', onVisible);

	return () => {
		document.removeEventListener('visibilitychange', onVisible);
	};
});

function formatDate(value: string | null): string {
	if (!value) return 'never';

	return new Date(value).toLocaleString();
}

function modelOptionLabel(item: ProviderModelCatalogItem): string {
	if (!item.label.trim() || item.label === item.upstreamModel) return item.upstreamModel;

	return `${item.label} · ${item.upstreamModel}`;
}

async function load(options?: { silent?: boolean }): Promise<void> {
	if (!options?.silent) {
		loading = true;
		error = null;
	}

	const [wakeResult, catalogResult] = await Promise.allSettled([Api.wakePingStatus(), Api.fetchAvailableModels('claude')]);

	if (wakeResult.status === 'fulfilled') {
		status = wakeResult.value;
		if (!saving) {
			workStart = status.workStart;
			workEnd = status.workEnd;
			model = status.model;
		}
	} else {
		error = wakeResult.reason instanceof Error ? wakeResult.reason.message : String(wakeResult.reason);
	}

	if (catalogResult.status === 'fulfilled') {
		catalog = [...catalogResult.value.models].sort(
			(left, right) => left.label.localeCompare(right.label) || left.upstreamModel.localeCompare(right.upstreamModel)
		);
		catalogLoaded = true;
		catalogError = null;
	} else {
		catalogError = catalogResult.reason instanceof Error ? catalogResult.reason.message : String(catalogResult.reason);
	}

	loading = false;
}

async function setEnabled(event: Event): Promise<void> {
	const enabled = (event.currentTarget as HTMLInputElement).checked;
	saving = true;
	error = null;

	try {
		await Api.updateWakePing({ enabled });
		await load({ silent: true });
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
		await load({ silent: true });
	} catch (reason) {
		error = reason instanceof Error ? reason.message : String(reason);
	} finally {
		saving = false;
	}
}

async function saveModel(): Promise<void> {
	const previousModel = status?.model;
	if (!previousModel || model === previousModel) return;

	saving = true;
	error = null;

	try {
		await Api.updateWakePing({ model });
		await load({ silent: true });
	} catch (reason) {
		model = previousModel;
		error = reason instanceof Error ? reason.message : String(reason);
	} finally {
		saving = false;
	}
}

async function sendNow(): Promise<void> {
	sending = true;
	error = null;

	try {
		await Api.sendWakePing();

		await load({ silent: true });
	} catch (reason) {
		await load({ silent: true });
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

		<label class="label">
			<span class="label-text text-xs">Claude model</span>
			<select
				class="select text-sm font-mono"
				bind:value={model}
				disabled={saving || !catalogLoaded}
				onchange={() => void saveModel()}>
				{#if model && !catalog.some((item) => item.upstreamModel === model)}
					<option value={model}>{modelUnavailable ? `${model} (unavailable)` : model}</option>
				{/if}
				{#each catalog as item (item.upstreamModel)}
					<option value={item.upstreamModel}>{modelOptionLabel(item)}</option>
				{/each}
			</select>
			<span class="text-xs text-surface-400">Only Claude models. This list is checked again when you return to the page.</span>
		</label>

		{#if modelUnavailable}
			<p class="text-xs text-warning-400">
				{status.model} is no longer in the Claude catalog. Scheduled pings still use it and will fail until you choose another model.
			</p>
		{/if}

		{#if catalogError}
			<p class="text-xs text-warning-400">Couldn't check whether {status.model} is still available: {catalogError}</p>
		{/if}

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
			<p class="text-xs text-error-500">Last ping for {status.model} failed: {status.lastPingError}</p>
		{/if}
	{/if}

	{#if error}
		<div class="card preset-tonal-error p-3 text-sm">{error}</div>
	{/if}
</div>
