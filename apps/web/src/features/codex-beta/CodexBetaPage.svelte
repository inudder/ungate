<script lang="ts">
import { onMount, tick } from 'svelte';

import { dashboardClient } from '$shared/dashboard-client';

import type { LauncherModelState, LauncherOperation, LauncherState } from '@ungate/shared/frontend';

type Section = 'models' | 'picker' | 'memory' | 'logging' | 'diagnostics';
type CapName =
	| 'supportsImageInput'
	| 'supportsImageDetailOriginal'
	| 'supportedReasoningLevels'
	| 'defaultReasoningLevel'
	| 'supportsReasoningSummaries'
	| 'defaultReasoningSummary'
	| 'supportsParallelToolCalls'
	| 'supportVerbosity'
	| 'defaultVerbosity';
type CapValue = boolean | string | string[] | null;
interface CapDraft {
	inherit: boolean;
	value: CapValue;
}
interface CatalogResult {
	available: boolean;
	models: string[];
	message: string | null;
}

const capabilityNames: CapName[] = [
	'supportsImageInput',
	'supportsImageDetailOriginal',
	'supportedReasoningLevels',
	'defaultReasoningLevel',
	'supportsReasoningSummaries',
	'defaultReasoningSummary',
	'supportsParallelToolCalls',
	'supportVerbosity',
	'defaultVerbosity'
];
const booleanFields: [CapName, string][] = [
	['supportsImageInput', 'Изображения'],
	['supportsImageDetailOriginal', 'Original detail'],
	['supportsReasoningSummaries', 'Reasoning summaries'],
	['supportsParallelToolCalls', 'Параллельные tool calls'],
	['supportVerbosity', 'Verbosity']
];
const summaryModes = ['none', 'auto', 'concise', 'detailed'];
const verbosityLevels = ['low', 'medium', 'high'];

let page = $state<LauncherState | null>(null);
let loadError = $state('');
let startCommand = $state('');
let notice = $state('');
let section = $state<Section>('models');
let selectedId = $state('');
let query = $state('');
let transportFilter = $state('all');
let versionDraft = $state({ upstreamModel: '', displayName: '', contextWindow: '' });
let prefixDraft = $state('');
let capDraft = $state<Record<CapName, CapDraft>>(blankCaps());
let pickerDraft = $state<string[]>([]);
let memoryEnabled = $state(false);
let memoryProvider = $state('cliproxyapi');
let memoryModel = $state('gemini-3.8-flash-high');
let logDraft = $state('Standard');
let fallback = $state(false);
let launchModel = $state('');
let skipRestore = $state(false);
let noLogWatch = $state(false);
let launchLogLevel = $state('');
let addOpen = $state(false);
let addForm = $state<HTMLDivElement | null>(null);
let addError = $state('');
let addDraft = $state(blankAddDraft());
let catalogIds = $state<string[]>([]);
let catalogMessage = $state('');
let toolDraft = $state<string[]>([]);
let activeOp = $state<LauncherOperation | null>(null);
let reportText = $state('');
let busy = $state(false);

function blankAddDraft() {
	return {
		registryId: '',
		displayName: '',
		upstreamModel: '',
		contextWindow: '',
		transport: 'omniroute',
		defaultReasoningLevel: 'medium',
		supportsImageInput: false,
		supportsImageDetailOriginal: false,
		skipCatalogCheck: false
	};
}
function blankCaps(): Record<CapName, CapDraft> {
	const next = {} as Record<CapName, CapDraft>;
	for (const name of capabilityNames) next[name] = { inherit: true, value: name === 'supportedReasoningLevels' ? [] : null };

	return next;
}
function quote(value: string): string {
	const apostrophe = String.fromCharCode(39);

	return apostrophe + value.replaceAll(apostrophe, apostrophe + apostrophe) + apostrophe;
}
function asLevels(value: unknown): string[] {
	return Array.isArray(value) ? value.map((item) => String(item)) : [];
}
function explicitCaps(model: LauncherModelState): Record<string, unknown> {
	const bucket = model.explicit.capabilities;
	if (bucket && typeof bucket === 'object' && !Array.isArray(bucket)) return bucket as Record<string, unknown>;

	return {};
}
function explicitPrefix(model: LauncherModelState): string {
	const value = model.explicit.upstreamModelPrefix;

	return typeof value === 'string' ? value : '';
}
function upstreamText(value: string | null | undefined): string {
	return value ?? '';
}
function sameValue(left: CapValue, right: unknown): boolean {
	if (Array.isArray(left) || Array.isArray(right)) {
		const rightLevels = asLevels(right);
		const leftLevels = asLevels(left);

		return leftLevels.length === rightLevels.length && leftLevels.every((item, index) => item === rightLevels[index]);
	}

	return left === right || (left == null && right == null);
}
function isState(value: unknown): value is LauncherState {
	return Boolean(value) && typeof value === 'object' && value !== null && 'models' in value;
}

const selected = $derived(page?.models.find((model) => model.registryId === selectedId) ?? null);
const visible = $derived(
	(page?.models ?? []).filter((model) => {
		const haystack = (
			model.displayName +
			' ' +
			model.registryId +
			' ' +
			upstreamText(model.upstreamModel) +
			' ' +
			model.requestModel
		).toLowerCase();

		return haystack.includes(query.trim().toLowerCase()) && (transportFilter === 'all' || model.transport === transportFilter);
	})
);
const transports = $derived([...new Set((page?.models ?? []).map((model) => model.transport))]);
const templateModels = $derived(page?.templates?.models ?? []);
const versionDirty = $derived(
	Boolean(
		selected &&
		(versionDraft.upstreamModel !== upstreamText(selected.upstreamModel) ||
			versionDraft.displayName !== selected.displayName ||
			versionDraft.contextWindow !== String(selected.contextWindow))
	)
);
const prefixDirty = $derived(Boolean(selected && prefixDraft !== explicitPrefix(selected)));
const capsDirty = $derived.by(() => {
	if (!selected) return false;
	const explicit = explicitCaps(selected);

	return capabilityNames.some((name) => {
		const draft = capDraft[name];
		const wasExplicit = Object.prototype.hasOwnProperty.call(explicit, name);
		if (draft.inherit) return wasExplicit;

		return !sameValue(draft.value, wasExplicit ? explicit[name] : selected.capabilities[name]);
	});
});
const pickerDirty = $derived(Boolean(page && JSON.stringify(pickerDraft) !== JSON.stringify(page.picker.slugs)));
const memoryDirty = $derived.by(() => {
	if (!page) return false;
	const saved = page.memory.saved;

	return (
		memoryEnabled !== (saved?.enabled ?? false) ||
		memoryProvider !== (saved?.provider ?? page.memory.defaults.provider) ||
		memoryModel !== (saved?.model ?? page.memory.defaults.model)
	);
});
const logDirty = $derived(Boolean(page && logDraft !== (page.logging.level ?? 'Standard')));
const unsaved = $derived(versionDirty || prefixDirty || capsDirty || pickerDirty || memoryDirty || logDirty);
const imageOn = $derived(
	capDraft.supportsImageInput.inherit ? Boolean(selected?.image) : capDraft.supportsImageInput.value === true
);
const summariesOn = $derived(
	capDraft.supportsReasoningSummaries.inherit
		? Boolean(selected?.capabilities.supportsReasoningSummaries)
		: capDraft.supportsReasoningSummaries.value === true
);
const verbosityOn = $derived(
	capDraft.supportVerbosity.inherit ? Boolean(selected?.capabilities.supportVerbosity) : capDraft.supportVerbosity.value === true
);
const levelChoices = $derived(asLevels(capDraft.supportedReasoningLevels.value));
const launchCommand = $derived.by(() => {
	if (!page) return '';
	const parts = ['pwsh -NoProfile -File ' + quote(page.launch.entryPoint)];
	if (fallback) parts.push('-EnableProviderFallback');
	else if (launchModel) parts.push('-Model', quote(launchModel));
	if (skipRestore) parts.push('-SkipWorkspaceRestore');
	if (noLogWatch) parts.push('-NoLogWatch');
	else if (launchLogLevel) parts.push('-LogLevel', quote(launchLogLevel));

	return parts.join(' ');
});

function syncDrafts() {
	if (!selected) return;
	versionDraft = {
		upstreamModel: upstreamText(selected.upstreamModel),
		displayName: selected.displayName,
		contextWindow: String(selected.contextWindow)
	};
	prefixDraft = explicitPrefix(selected);
	const explicit = explicitCaps(selected);
	const next = blankCaps();
	for (const name of capabilityNames) {
		const inherited = !Object.prototype.hasOwnProperty.call(explicit, name);
		const raw = inherited ? selected.capabilities[name] : explicit[name];
		next[name] = { inherit: inherited, value: name === 'supportedReasoningLevels' ? asLevels(raw) : ((raw ?? null) as CapValue) };
	}
	capDraft = next;
}
function selectModel(registryId: string): void {
	if (selectedId === registryId) return;
	selectedId = registryId;
	syncDrafts();
}
function applyState(next: LauncherState) {
	page = next;
	if (!next.models.some((model) => model.registryId === selectedId)) selectedId = next.models[0]?.registryId ?? '';
	pickerDraft = [...next.picker.slugs];
	if (toolDraft.length === 0) toolDraft = [...next.picker.slugs];
	memoryEnabled = next.memory.saved?.enabled ?? false;
	memoryProvider = next.memory.saved?.provider ?? next.memory.defaults.provider;
	memoryModel = next.memory.saved?.model ?? next.memory.defaults.model;
	logDraft = next.logging.level ?? 'Standard';
	if (!launchModel) launchModel = next.picker.slugs[0] ?? '';
	if (next.activeOperation) activeOp = next.activeOperation;
	syncDrafts();
}
async function load() {
	try {
		applyState(await dashboardClient.launcherState());
		loadError = '';
		startCommand = '';
	} catch (caught) {
		const error = caught as Error & { startCommand?: string };
		loadError = error.message || 'Компонент управления не запущен';
		startCommand = error.startCommand ?? '';
		page = null;
	}
}
async function save(path: string, body: unknown) {
	notice = '';
	busy = true;
	try {
		const result = await dashboardClient.launcherPost<LauncherState | { operationId?: string }>(path, body);
		if (!isState(result) && result.operationId) {
			notice = 'Проверка памяти запущена. Файл изменится только после успешной проверки.';
			const finished = await watchOperation(result.operationId);
			await load();
			notice =
				finished?.status === 'succeeded'
					? 'Память сохранена после проверки. Launcher применит её при следующем запуске.'
					: finished?.message || 'Проверка памяти не прошла. Сохранённые настройки не изменены.';

			return;
		}
		if (isState(result)) applyState(result);
		notice =
			'Сохранено. Launcher применит настройки при следующем запуске; для обновления Desktop catalog требуется повторный запуск Beta.';
	} catch (caught) {
		const error = caught as Error & { code?: string };
		notice =
			error.code === 'stale_revision'
				? error.message + ' Черновик оставлен. Нажмите Обновить, чтобы перечитать файл.'
				: error.message || 'Не удалось сохранить';
	} finally {
		busy = false;
	}
}
function saveVersion() {
	if (!selected || !versionDirty) {
		notice = 'Версия не изменилась.';

		return;
	}
	const set: Record<string, string> = {};
	const unset: string[] = [];
	if (versionDraft.upstreamModel !== upstreamText(selected.upstreamModel)) {
		if (versionDraft.upstreamModel.trim() === '') unset.push('upstreamModel');
		else set.upstreamModel = versionDraft.upstreamModel;
	}
	if (versionDraft.displayName !== selected.displayName) set.displayName = versionDraft.displayName;
	if (versionDraft.contextWindow !== String(selected.contextWindow)) set.contextWindow = versionDraft.contextWindow;
	void save('models/version', {
		profileId: 'default',
		registryId: selected.registryId,
		expectedRevision: selected.revisions.version,
		set,
		unset
	});
}
function savePrefix() {
	if (!selected || !prefixDirty) {
		notice = 'Prefix не изменился.';

		return;
	}
	void save('models/prefix', {
		profileId: 'default',
		registryId: selected.registryId,
		expectedRevision: selected.revisions.prefix,
		set: prefixDraft ? { upstreamModelPrefix: prefixDraft } : {},
		unset: prefixDraft ? [] : ['upstreamModelPrefix']
	});
}
function saveCapabilities() {
	if (!selected) return;
	const explicit = explicitCaps(selected);
	const set: Record<string, CapValue> = {};
	const unset: string[] = [];
	for (const name of capabilityNames) {
		const draft = capDraft[name];
		const wasExplicit = Object.prototype.hasOwnProperty.call(explicit, name);
		if (draft.inherit) {
			if (wasExplicit) unset.push(name);
			continue;
		}
		if (!wasExplicit || !sameValue(draft.value, explicit[name])) set[name] = draft.value;
	}
	if (Object.keys(set).length === 0 && unset.length === 0) {
		notice = 'Возможности не изменились.';

		return;
	}
	void save('models/capabilities', {
		profileId: 'default',
		registryId: selected.registryId,
		expectedRevision: selected.revisions.capabilities,
		set,
		unset
	});
}
function setBool(name: CapName, value: boolean) {
	capDraft[name] = { inherit: false, value };
	if (name === 'supportsImageInput' && !value) capDraft.supportsImageDetailOriginal = { inherit: false, value: false };
	if (name === 'supportsReasoningSummaries' && !value) capDraft.defaultReasoningSummary = { inherit: false, value: 'none' };
	if (name === 'supportVerbosity' && !value) capDraft.defaultVerbosity = { inherit: false, value: null };
}
function toggleLevel(level: string, checked: boolean) {
	const current = asLevels(capDraft.supportedReasoningLevels.value);
	const value = checked ? [...current, level] : current.filter((item) => item !== level);
	capDraft.supportedReasoningLevels = { inherit: false, value };
	if (!value.includes(String(capDraft.defaultReasoningLevel.value ?? '')))
		capDraft.defaultReasoningLevel = { inherit: false, value: value[0] ?? 'medium' };
}
async function discover(transport: string) {
	catalogMessage = '';
	try {
		const result = await dashboardClient.launcherPost<CatalogResult>('catalog', { profileId: 'default', transport });
		catalogIds = result.models ?? [];
		catalogMessage = result.available
			? 'Каталог получен. ID вне списка тоже можно ввести вручную.'
			: result.message || 'Каталог недоступен. Введите upstream ID вручную.';
	} catch (caught) {
		catalogIds = [];
		catalogMessage = caught instanceof Error ? caught.message : 'Каталог недоступен.';
	}
}
async function watchOperation(id: string): Promise<LauncherOperation | null> {
	for (let attempt = 0; attempt < 180; attempt += 1) {
		const operation = await dashboardClient.launcherOperation(id);
		activeOp = operation;
		if (operation.status !== 'queued' && operation.status !== 'running') {
			if (operation.reportId) reportText = JSON.stringify(await dashboardClient.launcherReport(operation.reportId), null, 2);

			return operation;
		}
		await new Promise((resolve) => setTimeout(resolve, 1000));
	}

	return activeOp;
}
async function startDiagnostic(kind: 'capabilities' | 'tools' | 'memory') {
	if (unsaved) {
		notice = 'Сначала сохраните или отмените черновик. Проверка читает только записанные настройки.';

		return;
	}
	const registryIds = kind === 'memory' ? [] : kind === 'tools' ? toolDraft : selectedId ? [selectedId] : [];
	if (kind !== 'memory' && registryIds.length === 0) {
		notice = 'Выберите хотя бы одну модель.';

		return;
	}
	busy = true;
	reportText = '';
	try {
		const operation = await dashboardClient.launcherPost<LauncherOperation>('diagnostics', {
			profileId: 'default',
			kind,
			registryIds,
			requestId: crypto.randomUUID()
		});
		activeOp = operation;
		await watchOperation(operation.id);
	} catch (caught) {
		notice = caught instanceof Error ? caught.message : 'Не удалось запустить проверку.';
	} finally {
		busy = false;
	}
}
async function cancelOperation() {
	if (!activeOp) return;
	await dashboardClient.launcherPost('operations/' + encodeURIComponent(activeOp.id) + '/cancel', {});
	await watchOperation(activeOp.id);
}
function removeSelected() {
	if (!selected) return;
	const question = selected.inTemplate
		? 'Удалить «' + selected.displayName + '»? Модель можно вернуть из шаблонов. Вернётся запись шаблона, не текущие правки.'
		: 'Удалить «' + selected.displayName + '»? Свою модель после удаления придётся ввести заново.';
	if (!window.confirm(question)) return;
	void save('models/remove', {
		profileId: 'default',
		registryId: selected.registryId,
		expectedRevision: selected.revisions.remove
	});
}
async function openAdd() {
	if (addOpen) {
		addOpen = false;

		return;
	}
	// Search text is the most likely ID the user wants; never clobber fields they already typed.
	addError = '';
	const typed = query.trim();
	if (typed) {
		if (!addDraft.registryId) addDraft.registryId = typed;
		if (!addDraft.upstreamModel) addDraft.upstreamModel = typed;
		if (!addDraft.displayName) addDraft.displayName = typed;
	}
	addOpen = true;
	await tick();
	addForm?.scrollIntoView({ behavior: 'smooth', block: 'center' });
	addForm?.querySelector<HTMLInputElement>('input')?.focus({ preventScroll: true });
}
async function addModel() {
	const registryId = addDraft.registryId.trim();
	const existed = page?.models.some((model) => model.registryId === registryId) ?? false;
	addError = '';
	await save('models/add', {
		profileId: 'default',
		expectedRevision: page?.registry.revision,
		...addDraft,
		registryId,
		supportsImageDetailOriginal: addDraft.supportsImageInput && addDraft.supportsImageDetailOriginal
	});
	if (existed || !page?.models.some((model) => model.registryId === registryId)) {
		// The page-level notice sits far above the form, so repeat the rejection next to the button.
		addError = notice;

		return;
	}
	selectModel(registryId);
	query = '';
	addDraft = blankAddDraft();
	addOpen = false;
	notice = 'Модель добавлена. Отметьте её на вкладке Picker, чтобы она появилась в Codex Desktop после перезапуска Beta.';
}
function addTemplateModel(registryId: string) {
	void save('models/add-template', {
		profileId: 'default',
		registryId,
		expectedRevision: page?.templates.revision
	});
}
function openSettings() {
	window.dispatchEvent(new CustomEvent('ungate-dashboard-page', { detail: 'settings' }));
}

onMount(() => {
	void load();

	return dashboardClient.subscribe((event) => {
		if (event.type === 'launcher-operation') activeOp = event.data;
	});
});
</script>

<section class="space-y-4">
	<header class="flex items-center justify-between gap-3">
		<div>
			<h1 class="text-lg font-semibold">Codex Beta</h1>
			<p class="text-sm text-surface-300">Настройки launcher. Запись не перезапускает Beta.</p>
		</div>
		<button
			class="btn btn-sm preset-tonal-surface"
			onclick={() => void load()}>Обновить</button>
	</header>
	{#if loadError}
		<div class="rounded-xl border border-warning-500/40 p-4 text-sm">
			<p>Компонент управления не запущен. Остальные вкладки dashboard продолжают работать.</p>
			{#if startCommand}<pre class="mt-2 overflow-auto text-xs">{startCommand}</pre>{/if}
		</div>
	{:else if page}
		<p class="text-xs text-surface-400"
			>Профиль: {page.betaHome}. Picker: {page.picker.slugs.length} из {page.picker.capacity}.{#if unsaved}
				Есть несохранённые изменения.{/if}</p>
		{#if page.definitionError}<p class="text-sm text-warning-400">Реестр повреждён: {page.definitionError}</p>{/if}
		{#if notice}<p class="text-sm text-primary-300">{notice}</p>{/if}
		<nav class="flex flex-wrap gap-1">
			{#each [['models', 'Модели'], ['picker', 'Picker'], ['memory', 'Память'], ['logging', 'Логирование'], ['diagnostics', 'Диагностика']] as item}
				<button
					class="btn btn-sm {section === item[0] ? 'preset-filled-primary-500' : 'preset-tonal-surface'}"
					onclick={() => (section = item[0] as Section)}>{item[1]}</button>
			{/each}
		</nav>
		{#if section === 'models' && selected}
			<div class="grid gap-4 lg:grid-cols-[18rem_1fr]">
				<div class="space-y-2">
					<input
						class="input text-sm"
						placeholder="Название, ID или upstream"
						bind:value={query} />
					<select
						class="select text-sm"
						bind:value={transportFilter}
						><option value="all">Все транспорты</option>{#each transports as transport}<option value={transport}
								>{transport}</option
							>{/each}</select>
					<ul class="max-h-[28rem] space-y-1 overflow-auto text-sm">
						{#each visible as model (model.registryId)}
							<li
								><button
									class="w-full rounded px-2 py-1 text-left {selectedId === model.registryId ? 'bg-primary-500/15' : ''}"
									onclick={() => selectModel(model.registryId)}
									>{model.displayName}<span class="block text-xs text-surface-400"
										>{model.registryId} · {model.requestModel} · {model.inTemplate ? 'из шаблона' : 'своя'}</span
									></button
								></li>
						{/each}
					</ul>
					{#if visible.length === 0 && query.trim()}
						<p class="text-xs text-surface-400">Модель «{query.trim()}» не найдена. Её можно добавить как custom-модель.</p>
					{/if}
					<button
						class="btn btn-sm preset-tonal-surface"
						onclick={() => void openAdd()}
						>{addOpen
							? 'Скрыть новую модель'
							: visible.length === 0 && query.trim()
								? 'Добавить «' + query.trim() + '»'
								: 'Добавить модель'}</button>
					{#if templateModels.length > 0}
						<div class="space-y-1 rounded-xl border border-surface-700/50 p-3 text-xs">
							<p class="text-surface-400">Добавить из шаблонов</p>
							{#each templateModels as templateModel (templateModel.registryId)}
								<div class="flex items-center justify-between gap-2">
									<span>{templateModel.displayName}</span>
									<button
										class="btn btn-sm preset-tonal-surface"
										disabled={busy}
										onclick={() => addTemplateModel(templateModel.registryId)}>Добавить</button>
								</div>
							{/each}
						</div>
					{/if}
				</div>
				<div class="space-y-4 text-sm">
					<div class="rounded-xl border border-surface-700/50 p-4">
						<p
							>Native {selected.nativeUpstream}; request {selected.requestModel}; transport {selected.transport}; endpoint {selected.endpoint ||
								'не задан'}.</p>
						<p class="text-xs text-surface-400"
							>Adapter: {selected.adapter || 'нет'}. Bridge: {selected.bridgeRequired ? 'нужен' : 'не нужен'}. Ключ: {selected.credentialAvailable
								? 'есть'
								: 'нет'} ({selected.credentialSource}). Provenance: {selected.provenance.upstreamModel} / {selected.provenance
								.capabilities}.</p>
						<button
							class="btn btn-sm preset-tonal-surface mt-2"
							onclick={openSettings}>Ключи Ungate API на вкладке Settings</button>
					</div>
					<div class="space-y-2 rounded-xl border border-surface-700/50 p-4">
						<p class="font-medium">Версия</p>
						<label class="block text-xs text-surface-400"
							>Upstream<input
								class="input mt-1"
								bind:value={versionDraft.upstreamModel}
								list="catalog-ids" /></label>
						<label class="block text-xs text-surface-400"
							>Название<input
								class="input mt-1"
								bind:value={versionDraft.displayName} /></label>
						<label class="block text-xs text-surface-400"
							>Контекст, токены или 200k/1M<input
								class="input mt-1"
								bind:value={versionDraft.contextWindow} /></label>
						<div class="flex flex-wrap gap-2">
							<button
								class="btn btn-sm preset-filled-primary-500"
								disabled={busy}
								onclick={saveVersion}>Сохранить версию</button>
							<button
								class="btn btn-sm preset-tonal-surface"
								disabled={busy}
								onclick={() =>
									selected &&
									void save('models/reset', {
										profileId: 'default',
										registryId: selected.registryId,
										expectedRevision: selected.revisions.version,
										scope: 'version'
									})}>Сбросить версию</button>
							<button
								class="btn btn-sm preset-tonal-surface"
								onclick={() => selected && void discover(selected.transport)}>Каталог upstream</button>
						</div>
						{#if catalogMessage}<p class="text-xs text-surface-400">{catalogMessage}</p>{/if}
						<datalist id="catalog-ids"
							>{#each catalogIds as id}<option value={id}></option>{/each}</datalist>
					</div>
					<div class="space-y-2 rounded-xl border border-surface-700/50 p-4">
						<p class="font-medium">Transport prefix</p>
						<p class="text-xs text-surface-400">Это не флаг изображений. Сброс версии его не удаляет.</p>
						<input
							class="input"
							bind:value={prefixDraft}
							placeholder="Пусто снимает явный prefix" />
						<div class="flex flex-wrap gap-2">
							<button
								class="btn btn-sm preset-filled-primary-500"
								disabled={busy}
								onclick={savePrefix}>Сохранить prefix</button>
							<button
								class="btn btn-sm preset-tonal-surface"
								disabled={busy}
								onclick={() =>
									selected &&
									void save('models/reset', {
										profileId: 'default',
										registryId: selected.registryId,
										expectedRevision: selected.revisions.prefix,
										scope: 'transport-prefix'
									})}>Сбросить prefix</button>
						</div>
					</div>
					<div class="space-y-3 rounded-xl border border-surface-700/50 p-4">
						<p class="font-medium">Возможности</p>
						<label class="flex gap-2"
							><input
								type="checkbox"
								checked
								disabled /> Текст, всегда включён</label>
						{#each booleanFields as field}
							<div class="flex flex-wrap items-center gap-3">
								<label class="flex gap-2 text-xs text-surface-400"
									><input
										type="checkbox"
										checked={capDraft[field[0]].inherit}
										onchange={(event) =>
											(capDraft[field[0]] = { ...capDraft[field[0]], inherit: event.currentTarget.checked })} /> Наследовать</label>
								<label class="flex gap-2"
									><input
										type="checkbox"
										checked={capDraft[field[0]].value === true}
										disabled={capDraft[field[0]].inherit || (field[0] === 'supportsImageDetailOriginal' && !imageOn)}
										onchange={(event) => setBool(field[0], event.currentTarget.checked)} />
									{field[1]}</label>
							</div>
						{/each}
						<div>
							<label class="flex gap-2 text-xs text-surface-400"
								><input
									type="checkbox"
									checked={capDraft.supportedReasoningLevels.inherit}
									onchange={(event) =>
										(capDraft.supportedReasoningLevels = {
											...capDraft.supportedReasoningLevels,
											inherit: event.currentTarget.checked
										})} /> Наследовать уровни reasoning</label>
							<div class="mt-1 flex flex-wrap gap-2">
								{#each page.launch.reasoningLevels as level}
									<label class="flex gap-1"
										><input
											type="checkbox"
											disabled={capDraft.supportedReasoningLevels.inherit}
											checked={levelChoices.includes(level)}
											onchange={(event) => toggleLevel(level, event.currentTarget.checked)} />
										{level}</label>
								{/each}
							</div>
						</div>
						<label class="block text-xs text-surface-400"
							>Default reasoning<select
								class="select mt-1"
								disabled={capDraft.defaultReasoningLevel.inherit}
								bind:value={capDraft.defaultReasoningLevel.value}
								>{#each levelChoices as level}<option value={level}>{level}</option>{/each}</select
							></label>
						<label class="flex gap-2 text-xs text-surface-400"
							><input
								type="checkbox"
								checked={capDraft.defaultReasoningLevel.inherit}
								onchange={(event) =>
									(capDraft.defaultReasoningLevel = {
										...capDraft.defaultReasoningLevel,
										inherit: event.currentTarget.checked
									})} /> Наследовать default reasoning</label>
						<label class="block text-xs text-surface-400"
							>Summary<select
								class="select mt-1"
								disabled={capDraft.defaultReasoningSummary.inherit || !summariesOn}
								bind:value={capDraft.defaultReasoningSummary.value}
								>{#each summaryModes as mode}<option value={mode}>{mode}</option>{/each}</select
							></label>
						<label class="block text-xs text-surface-400"
							>Verbosity<select
								class="select mt-1"
								disabled={capDraft.defaultVerbosity.inherit || !verbosityOn}
								bind:value={capDraft.defaultVerbosity.value}
								><option value={null}>null</option>{#each verbosityLevels as level}<option value={level}>{level}</option
									>{/each}</select
							></label>
						<div class="flex flex-wrap gap-2">
							<button
								class="btn btn-sm preset-filled-primary-500"
								disabled={busy}
								onclick={saveCapabilities}>Сохранить возможности</button>
							<button
								class="btn btn-sm preset-tonal-surface"
								disabled={busy}
								onclick={() =>
									selected &&
									void save('models/reset', {
										profileId: 'default',
										registryId: selected.registryId,
										expectedRevision: selected.revisions.capabilities,
										scope: 'capabilities'
									})}>Сбросить возможности</button>
						</div>
					</div>
					<div class="space-y-2 rounded-xl border border-surface-700/50 p-4">
						<p class="font-medium">Удаление</p>
						<p class="text-xs text-surface-400"
							>{selected.inTemplate
								? 'Модель из шаблона. После удаления её можно вернуть из шаблонов. Вернётся запись шаблона, не текущие правки.'
								: 'Свою модель после удаления придётся ввести заново.'}
							Из picker и настройки фоновых задач модель тоже убирается. Последнюю модель удалить нельзя.</p>
						<button
							class="btn btn-sm preset-tonal-error"
							disabled={busy}
							onclick={removeSelected}>Удалить модель</button>
					</div>
					{#if addOpen}
						<div
							class="space-y-2 rounded-xl border border-surface-700/50 p-4"
							bind:this={addForm}>
							<p class="font-medium">Новая custom-модель. Встроенные записи не переписываются.</p>
							<label class="block text-xs text-surface-400"
								>ID в launcher (registryId)<input
									class="input mt-1"
									placeholder="registryId"
									bind:value={addDraft.registryId} /></label>
							<label class="block text-xs text-surface-400"
								>Название в picker<input
									class="input mt-1"
									placeholder="Название"
									bind:value={addDraft.displayName} /></label>
							<label class="block text-xs text-surface-400"
								>Upstream<input
									class="input mt-1"
									placeholder="Upstream"
									bind:value={addDraft.upstreamModel}
									list="catalog-ids" /></label>
							<label class="block text-xs text-surface-400"
								>Контекст, токены или 200k/1M<input
									class="input mt-1"
									placeholder="Пусто — 200k"
									bind:value={addDraft.contextWindow} /></label>
							<label class="block text-xs text-surface-400"
								>Транспорт<select
									class="select mt-1"
									bind:value={addDraft.transport}
									><option value="ungate">ungate</option><option value="cliproxyapi">cliproxyapi</option><option value="omniroute"
										>omniroute</option
									></select
								></label>
							<label class="block text-xs text-surface-400"
								>Reasoning по умолчанию<select
									class="select mt-1"
									bind:value={addDraft.defaultReasoningLevel}
									>{#each page.launch.reasoningLevels as level}<option value={level}>{level}</option>{/each}</select
								></label>
							<label class="flex gap-2"
								><input
									type="checkbox"
									bind:checked={addDraft.supportsImageInput} /> Image</label>
							<label class="flex gap-2"
								><input
									type="checkbox"
									bind:checked={addDraft.supportsImageDetailOriginal}
									disabled={!addDraft.supportsImageInput} /> Original, по умолчанию выключен</label>
							<p class="text-xs text-surface-400"
								>Original разрешает Codex отправлять картинку в исходном разрешении (detail: original) вместо уменьшенной копии.
								Включайте, только если upstream это принимает: поддержка изображений её не подразумевает.</p>
							<label class="flex gap-2"
								><input
									type="checkbox"
									bind:checked={addDraft.skipCatalogCheck} /> Не сверять с каталогом транспорта</label>
							<p class="text-xs text-surface-400"
								>По умолчанию upstream сверяется с /v1/models выбранного транспорта, и добавление отклоняется, если модели там нет
								или каталог недоступен. Отключайте для моделей, которые транспорт обслуживает, но не публикует в каталоге.</p>
							{#if addError}<p class="text-sm text-error-400">{addError}</p>{/if}
							<button
								class="btn btn-sm preset-filled-primary-500"
								disabled={busy || !addDraft.registryId.trim()}
								onclick={() => void addModel()}>Добавить</button>
						</div>
					{/if}
				</div>
			</div>
		{:else if section === 'picker'}
			<div class="space-y-2 text-sm">
				<p
					>Выбрано {pickerDraft.length} из {page.picker.capacity}. Порядок отметок не сохраняется: launcher нормализует его по
					реестру. ungate-memory слот не занимает.</p>
				{#if page.picker.corrupt}<p class="text-warning-400"
						>Файл picker повреждён: {page.picker.message}. Сохранение поверх него отключено логикой сервера.</p
					>{/if}
				{#each page.models as model (model.registryId)}
					<label class="flex gap-2"
						><input
							type="checkbox"
							checked={pickerDraft.includes(model.registryId)}
							onchange={(event) => {
								pickerDraft = event.currentTarget.checked
									? [...pickerDraft, model.registryId]
									: pickerDraft.filter((id) => id !== model.registryId);
							}} />{model.displayName} <span class="text-surface-400">{model.registryId}</span></label>
				{/each}
				<button
					class="btn btn-sm preset-filled-primary-500"
					disabled={busy}
					onclick={() =>
						void save('picker', { profileId: 'default', registryIds: pickerDraft, expectedRevision: page?.picker.revision })}
					>Сохранить picker</button>
			</div>
		{:else if section === 'memory'}
			<div class="space-y-2 text-sm">
				<p>Документированный default: Off / {page.memory.defaults.provider} / {page.memory.defaults.model}.</p>
				<p
					>Сохранено: {page.memory.saved
						? (page.memory.saved.enabled ? 'включена' : 'выключена') +
							', ' +
							page.memory.saved.provider +
							' / ' +
							page.memory.saved.model
						: 'файла нет, действует default'}.</p>
				{#if page.memory.corrupt}<p class="text-warning-400">Файл памяти повреждён: {page.memory.message}</p>{/if}
				<label class="flex gap-2"
					><input
						type="checkbox"
						bind:checked={memoryEnabled} /> Включена</label>
				<input
					class="input"
					bind:value={memoryProvider} /><input
					class="input"
					bind:value={memoryModel} />
				<div class="flex flex-wrap gap-2">
					<button
						class="btn btn-sm preset-filled-primary-500"
						disabled={busy}
						onclick={() =>
							void save('memories', {
								profileId: 'default',
								enabled: memoryEnabled,
								provider: memoryProvider,
								model: memoryModel,
								expectedRevision: page?.memory.revision,
								requestId: crypto.randomUUID()
							})}>Сохранить память</button>
					<button
						class="btn btn-sm preset-tonal-surface"
						onclick={() => {
							if (!page) return;
							memoryProvider = page.memory.defaults.provider;
							memoryModel = page.memory.defaults.model;
						}}>Вернуть модель по умолчанию</button>
					<button
						class="btn btn-sm preset-tonal-surface"
						disabled={busy || unsaved}
						onclick={() => void startDiagnostic('memory')}>Проверить сохранённую модель</button>
				</div>
				<p class="text-xs text-surface-400"
					>Включение и смена модели при включённой памяти сначала проходят отдельную проверку extraction/consolidation. Ошибка не
					затирает сохранённое значение.</p>
			</div>
		{:else if section === 'logging'}
			<div class="space-y-2 text-sm">
				<p>Уровень live logger launcher. Это не журнал вкладки Logs и не quiet Ungate API.</p>
				{#if page.logging.corrupt}<p class="text-warning-400">Файл логов повреждён: {page.logging.message}</p>{/if}
				<select
					class="select"
					bind:value={logDraft}
					>{#each page.launch.logLevels as level}<option value={level}>{level}</option>{/each}</select>
				<button
					class="btn btn-sm preset-filled-primary-500"
					disabled={busy}
					onclick={() =>
						void save('logging', { profileId: 'default', level: logDraft, expectedRevision: page?.logging.revision })}
					>Сохранить уровень</button>
			</div>
		{:else}
			<div class="space-y-3 text-sm">
				<p>Проверяются только сохранённые настройки. Открытие вкладки ничего не вызывает.</p>
				{#if unsaved}<p class="text-warning-400">Есть несохранённый черновик. Сохраните его или нажмите Обновить.</p>{/if}
				<div class="flex flex-wrap gap-2">
					<button
						class="btn btn-sm preset-filled-primary-500"
						disabled={busy || unsaved}
						onclick={() => void startDiagnostic('capabilities')}>Проверить возможности выбранной модели</button>
					<button
						class="btn btn-sm preset-filled-primary-500"
						disabled={busy || unsaved}
						onclick={() => void startDiagnostic('tools')}>Проверить инструменты</button>
					{#if activeOp && (activeOp.status === 'queued' || activeOp.status === 'running')}<button
							class="btn btn-sm preset-tonal-surface"
							onclick={() => void cancelOperation()}>Отменить</button
						>{/if}
				</div>
				<div class="space-y-1">
					{#each page.models as model (model.registryId)}
						<label class="flex gap-2"
							><input
								type="checkbox"
								checked={toolDraft.includes(model.registryId)}
								onchange={(event) => {
									toolDraft = event.currentTarget.checked
										? [...toolDraft, model.registryId]
										: toolDraft.filter((id) => id !== model.registryId);
								}} />{model.displayName}</label>
					{/each}
				</div>
				{#if activeOp}<p
						>Операция {activeOp.id}: {activeOp.status}{activeOp.stage ? ', ' + activeOp.stage : ''}{activeOp.message
							? '. ' + activeOp.message
							: ''}</p
					>{/if}
				{#if reportText}<pre class="max-h-80 overflow-auto rounded-xl border border-surface-700/50 p-3 text-xs">{reportText}</pre
					>{/if}
			</div>
		{/if}
		<div class="rounded-xl border border-surface-700/50 p-4 text-sm">
			<p>Следующий запуск. Копирование команды ничего не запускает и не пишет новый файл defaults.</p>
			<p class="text-xs text-surface-400"
				>Fallback: Claude, затем Grok, MiniMax и Gemini. Цепочка не редактируется. -LogLevel, в отличие от остальных флагов, ещё и
				сохраняет уровень логов.</p>
			<label class="flex gap-2"
				><input
					type="checkbox"
					bind:checked={fallback} /> -EnableProviderFallback без -Model</label>
			{#if !fallback}<label class="block text-xs text-surface-400"
					>Модель из picker<select
						class="select mt-1"
						bind:value={launchModel}
						>{#each page.picker.slugs as slug}<option value={slug}>{slug}</option>{/each}</select
					></label
				>{/if}
			<label class="flex gap-2"
				><input
					type="checkbox"
					bind:checked={skipRestore} /> -SkipWorkspaceRestore</label>
			<label class="flex gap-2"
				><input
					type="checkbox"
					bind:checked={noLogWatch} /> -NoLogWatch</label>
			{#if !noLogWatch}<label class="block text-xs text-surface-400"
					>Необязательный -LogLevel<select
						class="select mt-1"
						bind:value={launchLogLevel}
						><option value="">не передавать</option>{#each page.launch.logLevels as level}<option value={level}>{level}</option
							>{/each}</select
					></label
				>{/if}
			<pre class="overflow-auto text-xs">{launchCommand}</pre>
		</div>
	{/if}
</section>
