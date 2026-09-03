<script lang="ts">
import { getProviderLabel, sleep } from '@ungate/shared/frontend';
import IconCheck from 'virtual:icons/lucide/check';
import IconCopy from 'virtual:icons/lucide/copy';
import IconLoader from 'virtual:icons/lucide/loader-circle';
import IconPlay from 'virtual:icons/lucide/play';
import IconRefresh from 'virtual:icons/lucide/refresh-cw';
import IconSearch from 'virtual:icons/lucide/search';
import IconTrash2 from 'virtual:icons/lucide/trash-2';
import IconX from 'virtual:icons/lucide/x';

import { Api } from '$shared/api';

import type {
	ModelMappingConfig,
	ModelMappingProvider,
	ModelValidationResult,
	ProviderModelCatalogItem
} from '@ungate/shared/frontend';

interface VisibleModelItem {
	model: ModelMappingConfig;
	index: number;
}

interface Props {
	selectedProvider: ModelMappingProvider;
	providerAuthorized: boolean;
	providerAuthLoading: boolean;
	models: ModelMappingConfig[];
	onModelsChange: (nextModels: ModelMappingConfig[]) => void;
	onSave: () => void;
	saving: boolean;
	saved: boolean;
	restarting: boolean;
}

let {
	selectedProvider,
	providerAuthorized,
	providerAuthLoading,
	models,
	onModelsChange,
	onSave,
	saving,
	saved,
	restarting
}: Props = $props();

let copiedId = $state<string | null>(null);
let confirmDeleteModelId = $state<string | null>(null);
let confirmDeleteIndex = $state<number | null>(null);
let activeModelIndex = $state<number | null>(null);
let validatingIndex = $state<number | null>(null);
let validationByIndex = $state<Record<number, ModelValidationResult | null>>({});
let catalogProvider = $state<ModelMappingProvider | null>(null);
let catalogModels = $state<ProviderModelCatalogItem[]>([]);
let selectedCatalogIds = $state<string[]>([]);
let catalogSearch = $state('');
let catalogLoading = $state(false);
let catalogError = $state<string | null>(null);

const reasoningOptions: { label: string; value: ModelMappingConfig['reasoningBudget'] }[] = [
	{ label: 'None', value: null },
	{ label: 'Low', value: 'low' },
	{ label: 'Medium', value: 'medium' },
	{ label: 'High', value: 'high' },
	{ label: 'XHigh', value: 'xhigh' }
];

function withSortOrder(items: ModelMappingConfig[]): ModelMappingConfig[] {
	return items.map((model, index) => ({ ...model, sortOrder: index }));
}

function commit(nextModels: ModelMappingConfig[]) {
	onModelsChange(withSortOrder(nextModels));
}

function visibleModels(): VisibleModelItem[] {
	return models.map((model, index) => ({ model, index })).filter((item) => item.model.provider === selectedProvider);
}

function activeVisibleModel(): VisibleModelItem | null {
	if (activeModelIndex === null) {
		return null;
	}

	const active = visibleModels().find((item) => item.index === activeModelIndex);

	if (!active) {
		return null;
	}

	return active;
}

function modelTitle(item: VisibleModelItem): string {
	if (item.model.label.trim()) {
		return item.model.label;
	}

	if (item.model.id.trim()) {
		return item.model.id;
	}

	return `Model ${item.index + 1}`;
}

function setActiveModel(index: number) {
	if (activeModelIndex === index) {
		activeModelIndex = null;

		return;
	}

	activeModelIndex = index;
}

function addModel() {
	const nextIndex = models.length;

	commit([
		...models,
		{
			id: '',
			label: '',
			provider: selectedProvider,
			upstreamModel: '',
			sortOrder: models.length,
			reasoningBudget: null
		}
	]);

	activeModelIndex = nextIndex;
}

function catalogKey(upstreamModel: string): string {
	return upstreamModel.trim().toLowerCase();
}

function isAlreadyAdded(item: ProviderModelCatalogItem): boolean {
	if (!catalogProvider) return false;

	const key = catalogKey(item.upstreamModel);

	return models.some((model) => model.provider === catalogProvider && catalogKey(model.upstreamModel) === key);
}

function filteredCatalogModels(): ProviderModelCatalogItem[] {
	const search = catalogSearch.trim().toLowerCase();
	if (!search) return catalogModels;

	return catalogModels.filter(
		(item) => item.upstreamModel.toLowerCase().includes(search) || item.label.toLowerCase().includes(search)
	);
}

function selectedCatalogCount(): number {
	return catalogModels.filter((item) => selectedCatalogIds.includes(catalogKey(item.upstreamModel)) && !isAlreadyAdded(item))
		.length;
}

function toggleCatalogModel(item: ProviderModelCatalogItem) {
	if (isAlreadyAdded(item)) return;

	const key = catalogKey(item.upstreamModel);
	selectedCatalogIds = selectedCatalogIds.includes(key)
		? selectedCatalogIds.filter((selectedKey) => selectedKey !== key)
		: [...selectedCatalogIds, key];
}

async function loadCatalog() {
	if (!catalogProvider || catalogLoading) return;

	catalogLoading = true;
	catalogError = null;

	try {
		const response = await Api.fetchAvailableModels(catalogProvider);
		catalogModels = response.models;
		selectedCatalogIds = [];
	} catch (error) {
		catalogModels = [];
		catalogError = error instanceof Error ? error.message : 'Failed to load provider models.';
	} finally {
		catalogLoading = false;
	}
}

function openCatalog() {
	if (!providerAuthorized || providerAuthLoading) return;

	catalogProvider = selectedProvider;
	catalogModels = [];
	selectedCatalogIds = [];
	catalogSearch = '';
	catalogError = null;
	void loadCatalog();
}

function closeCatalog() {
	if (catalogLoading) return;

	catalogProvider = null;
	catalogModels = [];
	selectedCatalogIds = [];
	catalogSearch = '';
	catalogError = null;
}

function uniqueLocalId(upstreamModel: string, provider: ModelMappingProvider, usedIds: Set<string>): string {
	const baseId = upstreamModel.trim();
	let candidate = baseId;
	let suffix = 2;

	if (usedIds.has(candidate.toLowerCase())) {
		candidate = `${baseId}-${provider}`;
	}

	while (usedIds.has(candidate.toLowerCase())) {
		candidate = `${baseId}-${provider}-${suffix}`;
		suffix += 1;
	}

	usedIds.add(candidate.toLowerCase());

	return candidate;
}

function addSelectedModels() {
	if (!catalogProvider) return;
	const provider = catalogProvider;

	const selected = catalogModels.filter(
		(item) => selectedCatalogIds.includes(catalogKey(item.upstreamModel)) && !isAlreadyAdded(item)
	);
	if (selected.length === 0) return;

	const usedIds = new Set(models.map((model) => model.id.trim().toLowerCase()));
	const additions = selected.map(
		(item, offset): ModelMappingConfig => ({
			id: uniqueLocalId(item.upstreamModel, provider, usedIds),
			label: item.label,
			provider,
			upstreamModel: item.upstreamModel,
			sortOrder: models.length + offset,
			reasoningBudget: null
		})
	);
	const firstAddedIndex = models.length;

	commit([...models, ...additions]);
	activeModelIndex = firstAddedIndex;
	closeCatalog();
}

function inputValue(event: Event): string {
	const target = event.target;

	if (!target || !(target instanceof HTMLInputElement)) {
		return '';
	}

	return target.value;
}

function selectValue(event: Event): string {
	const target = event.target;

	if (!target || !(target instanceof HTMLSelectElement)) {
		return '';
	}

	return target.value;
}

function updateModelAtIndex(index: number, key: keyof ModelMappingConfig, value: string | number | null) {
	clearValidation(index);
	commit(
		models.map((model, modelIndex) => {
			if (modelIndex !== index) {
				return model;
			}

			if (key === 'reasoningBudget') {
				if (value === 'low' || value === 'medium' || value === 'high' || value === 'xhigh' || value === null) {
					return { ...model, reasoningBudget: value };
				}

				return { ...model, reasoningBudget: null };
			}

			return { ...model, [key]: value };
		})
	);
}

async function copyModelId(id: string) {
	if (!id.trim()) {
		return;
	}

	await navigator.clipboard.writeText(id);
	copiedId = id;
	void (async () => {
		await sleep(1500);

		if (copiedId === id) {
			copiedId = null;
		}
	})();
}

async function testModel(model: ModelMappingConfig, index: number) {
	if (!model.id.trim() || !model.upstreamModel.trim() || validatingIndex !== null) {
		return;
	}

	validatingIndex = index;
	validationByIndex = { ...validationByIndex, [index]: null };

	try {
		const result = await Api.validateModel(model);
		validationByIndex = { ...validationByIndex, [index]: result };
	} catch (error) {
		validationByIndex = {
			...validationByIndex,
			[index]: {
				ok: false,
				available: false,
				message: error instanceof Error ? error.message : 'Validation request failed.',
				provider: model.provider,
				upstreamModel: model.upstreamModel
			}
		};
	} finally {
		validatingIndex = null;
	}
}

function clearValidation(index: number) {
	if (validationByIndex[index]) {
		validationByIndex = { ...validationByIndex, [index]: null };
	}
}

function requestDelete(id: string, index: number) {
	confirmDeleteModelId = id;
	confirmDeleteIndex = index;
}

function cancelDelete() {
	confirmDeleteModelId = null;
	confirmDeleteIndex = null;
}

function confirmDelete() {
	if (confirmDeleteIndex === null) {
		return;
	}

	commit(models.filter((_, modelIndex) => modelIndex !== confirmDeleteIndex));
	cancelDelete();
}

$effect(() => {
	const visible = visibleModels();

	if (visible.length === 0) {
		activeModelIndex = null;

		return;
	}

	const active = visible.find((item) => item.index === activeModelIndex);

	if (!active) {
		activeModelIndex = visible[0].index;
	}
});
</script>

<div class="card preset-tonal-surface border border-surface-700/30 p-5 space-y-4">
	<div class="flex items-center justify-between gap-3">
		<div class="space-y-1">
			<p class="text-sm font-semibold">Models · {getProviderLabel(selectedProvider)}</p>
			<p class="text-xs text-surface-400"> Use these IDs when adding custom models in Cursor. </p>
		</div>
		<div class="flex items-center gap-2">
			<button
				class="btn btn-sm preset-outlined-surface-700 hover:preset-filled-surface-500"
				type="button"
				onclick={openCatalog}
				disabled={!providerAuthorized || providerAuthLoading}>
				{providerAuthLoading ? 'Checking Provider...' : 'Choose Provider Models'}
			</button>
			<button
				class="btn btn-sm preset-outlined-surface-700 hover:preset-filled-surface-500"
				type="button"
				onclick={addModel}>
				Add Manually
			</button>
			<button
				class="btn btn-sm preset-filled-primary-500"
				type="button"
				onclick={onSave}
				disabled={saving || restarting}>
				{saved ? 'Saved' : 'Save'}
			</button>
		</div>
	</div>
	{#if !providerAuthLoading && !providerAuthorized}
		<p class="text-xs text-warning-400">Connect {getProviderLabel(selectedProvider)} above to load its model catalog.</p>
	{/if}

	<div class="space-y-3">
		{#if visibleModels().length === 0}
			<div class="card preset-tonal-surface border border-surface-700/30 p-4 text-sm text-surface-400">
				No models for {getProviderLabel(selectedProvider)}.
			</div>
		{:else}
			<div>
				<div class="flex flex-wrap gap-2">
					{#each visibleModels() as item}
						<button
							type="button"
							class="btn btn-sm h-auto min-h-0 px-3 py-1.5 border {activeModelIndex === item.index
								? 'preset-filled-primary-500 border-primary-500/50'
								: 'preset-tonal-surface border-surface-600 hover:border-surface-400 hover:preset-filled-surface-500'}"
							onclick={() => setActiveModel(item.index)}>
							{modelTitle(item)}
						</button>
					{/each}
				</div>
			</div>

			{#if activeVisibleModel()}
				{@const activeItem = activeVisibleModel()!}
				{@const model = activeItem.model}
				{@const index = activeItem.index}
				<div class="card preset-tonal-surface border border-surface-700/30 p-4 space-y-3">
					<div class="flex items-center justify-between gap-3">
						<p class="text-sm font-medium">{modelTitle(activeItem)}</p>
						<div class="flex items-center gap-2">
							<button
								class="btn btn-sm preset-outlined-surface-700 hover:preset-filled-surface-500"
								type="button"
								onclick={() => void copyModelId(model.id)}
								disabled={!model.id.trim()}>
								<IconCopy class="size-4" />
								{copiedId === model.id ? 'Copied' : 'Copy ID'}
							</button>
							<button
								class="btn btn-sm preset-outlined-surface-700 hover:preset-filled-surface-500"
								type="button"
								onclick={() => void testModel(model, index)}
								disabled={!model.id.trim() || !model.upstreamModel.trim() || validatingIndex !== null}>
								{#if validatingIndex === index}
									<IconLoader class="size-4 animate-spin" />
									Testing
								{:else}
									<IconPlay class="size-4" />
									Test
								{/if}
							</button>
							<button
								class="btn btn-sm preset-outlined-error-500"
								type="button"
								onclick={() => requestDelete(model.id || `#row-${index + 1}`, index)}>
								<IconTrash2 class="size-4" />
								Remove
							</button>
						</div>
					</div>

					{#if validatingIndex === index || validationByIndex[index]}
						{@const result = validationByIndex[index]}
						{#if validatingIndex === index}
							<div class="card preset-tonal-warning border border-warning-500/30 flex items-center gap-2 p-3 text-sm">
								<IconLoader class="size-4 animate-spin" />
								<span>Testing model availability...</span>
							</div>
						{:else if result?.available}
							<div class="card preset-tonal-success border border-success-500/30 flex items-center gap-2 p-3 text-sm">
								<IconCheck class="size-4 shrink-0" />
								<span>Available{result.latencyMs != null ? ` (${result.latencyMs}ms)` : ''}</span>
							</div>
						{:else if result}
							<div class="card preset-tonal-error border border-error-500/30 flex items-start gap-2 p-3 text-sm">
								<IconX class="size-4 mt-0.5 shrink-0" />
								<span>{result.message}</span>
							</div>
						{/if}
					{/if}

					<div class="grid grid-cols-1 gap-4 xl:grid-cols-4 md:grid-cols-2">
						<label class="label">
							<span class="label-text text-xs">Model ID</span>
							<input
								class="input text-sm font-mono"
								type="text"
								value={model.id}
								oninput={(event) => updateModelAtIndex(index, 'id', inputValue(event))}
								placeholder="sonnet-4.6" />
						</label>

						<label class="label">
							<span class="label-text text-xs">Label</span>
							<input
								class="input text-sm"
								type="text"
								value={model.label}
								oninput={(event) => updateModelAtIndex(index, 'label', inputValue(event))}
								placeholder="Sonnet 4.6" />
						</label>

						<label class="label xl:col-span-1 md:col-span-2">
							<span class="label-text text-xs">Upstream Model</span>
							<input
								class="input text-sm font-mono"
								type="text"
								value={model.upstreamModel}
								oninput={(event) => updateModelAtIndex(index, 'upstreamModel', inputValue(event))}
								placeholder={selectedProvider === 'minimax' ? 'MiniMax-M2.7' : 'claude-sonnet-4-6'} />
						</label>

						<label class="label">
							<span class="label-text text-xs">Reasoning Budget</span>
							<select
								class="select text-sm"
								value={model.reasoningBudget ?? ''}
								onchange={(event) => {
									const value = selectValue(event);
									updateModelAtIndex(index, 'reasoningBudget', value ? value : null);
								}}>
								{#each reasoningOptions as option}
									<option value={option.value ?? ''}>{option.label}</option>
								{/each}
							</select>
						</label>
					</div>
				</div>
			{/if}
		{/if}
	</div>
</div>

{#if confirmDeleteModelId}
	<div class="fixed inset-0 z-30 flex items-center justify-center bg-surface-950/70 p-4">
		<div class="card preset-tonal-surface border border-surface-700/30 w-full max-w-md p-5 space-y-4">
			<p class="text-sm font-semibold">Remove model</p>
			<p class="text-sm text-surface-400">
				Confirm deletion for Model ID:
				<code class="code text-surface-950-50">{confirmDeleteModelId}</code>
			</p>
			<div class="flex justify-end gap-2">
				<button
					class="btn btn-sm preset-outlined-surface-700 hover:preset-filled-surface-500"
					type="button"
					onclick={cancelDelete}>
					Cancel
				</button>
				<button
					class="btn btn-sm preset-outlined-error-500"
					type="button"
					disabled={confirmDeleteIndex === null}
					onclick={confirmDelete}>
					<IconTrash2 class="size-4" />
					Remove
				</button>
			</div>
		</div>
	</div>
{/if}

{#if catalogProvider}
	<div class="fixed inset-0 z-30 flex items-center justify-center bg-surface-950/70 p-4">
		<div class="card preset-tonal-surface border border-surface-700/30 flex max-h-[80vh] w-full max-w-2xl flex-col p-5 space-y-4">
			<div class="flex items-start justify-between gap-3">
				<div class="space-y-1">
					<p class="text-sm font-semibold">Choose {getProviderLabel(catalogProvider)} models</p>
					<p class="text-xs text-surface-400">Models are added as unsaved, editable entries.</p>
				</div>
				<button
					class="btn btn-sm preset-outlined-surface-700"
					type="button"
					onclick={closeCatalog}
					disabled={catalogLoading}>
					<IconX class="size-4" />
				</button>
			</div>

			{#if catalogLoading}
				<div class="flex min-h-40 items-center justify-center gap-2 text-sm text-surface-400">
					<IconLoader class="size-4 animate-spin" />
					Loading provider models...
				</div>
			{:else if catalogError}
				<div class="card preset-tonal-error border border-error-500/30 p-4 space-y-3">
					<p class="text-sm">{catalogError}</p>
					<p class="text-xs opacity-80">If the session expired, reconnect the provider above and try again.</p>
					<button
						class="btn btn-sm preset-outlined-error-500"
						type="button"
						onclick={() => void loadCatalog()}>
						<IconRefresh class="size-4" />
						Retry
					</button>
				</div>
			{:else}
				<label class="input flex items-center gap-2">
					<IconSearch class="size-4 text-surface-400" />
					<input
						class="w-full bg-transparent text-sm outline-none"
						type="search"
						bind:value={catalogSearch}
						placeholder="Search models" />
				</label>

				<div class="min-h-0 flex-1 overflow-y-auto rounded-container border border-surface-700/30">
					{#if filteredCatalogModels().length === 0}
						<p class="p-4 text-sm text-surface-400">No models found.</p>
					{:else}
						{#each filteredCatalogModels() as item}
							{@const alreadyAdded = isAlreadyAdded(item)}
							<label
								class="flex items-center gap-3 border-b border-surface-700/30 p-3 last:border-b-0 {alreadyAdded
									? 'opacity-60'
									: 'cursor-pointer hover:bg-surface-500/10'}">
								<input
									type="checkbox"
									checked={selectedCatalogIds.includes(catalogKey(item.upstreamModel))}
									disabled={alreadyAdded}
									onchange={() => toggleCatalogModel(item)} />
								<span class="min-w-0 flex-1">
									<span class="block truncate text-sm font-medium">{item.label}</span>
									<span class="block truncate font-mono text-xs text-surface-400">{item.upstreamModel}</span>
								</span>
								{#if alreadyAdded}<span class="text-xs text-surface-400">Already added</span>{/if}
							</label>
						{/each}
					{/if}
				</div>
			{/if}

			<div class="flex justify-end gap-2">
				<button
					class="btn btn-sm preset-outlined-surface-700"
					type="button"
					onclick={closeCatalog}
					disabled={catalogLoading}>Cancel</button>
				<button
					class="btn btn-sm preset-filled-primary-500"
					type="button"
					onclick={addSelectedModels}
					disabled={catalogLoading || catalogError !== null || selectedCatalogCount() === 0}>
					Add selected{selectedCatalogCount() > 0 ? ` (${selectedCatalogCount()})` : ''}
				</button>
			</div>
		</div>
	</div>
{/if}
