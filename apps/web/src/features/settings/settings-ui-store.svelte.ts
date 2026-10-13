import { getProviderLabel } from '@ungate/shared/frontend';

import { Api } from '$shared/api';

import type { ClaudeAuthStatus, ModelMappingConfig, ModelMappingProvider } from '@ungate/shared/frontend';

export enum ProviderAuthState {
	Authorized = 'authorized',
	NotAuthorized = 'not-authorized',
	SessionExpired = 'session-expired',
	Loading = 'loading',
	RetryWait = 'retry-wait'
}

interface SettingsUiStore {
	readonly claudeStatus: ClaudeAuthStatus;
	readonly selectedProvider: ModelMappingProvider;
	readonly authStates: Record<ModelMappingProvider, ProviderAuthState>;
	readonly providerLabels: Record<ModelMappingProvider, string>;
	getProviderModelsCount(models: ModelMappingConfig[]): (provider: ModelMappingProvider) => number;
	setSelectedProvider(provider: ModelMappingProvider): void;
	refreshAuthStates(): Promise<void>;
	applyClaudeStatus(status: ClaudeAuthStatus): void;
}

let claudeStatus = $state<ClaudeAuthStatus>({ authenticated: false, state: 'disconnected' });
let selectedProvider = $state<ModelMappingProvider>('claude');

function createAuthStates(state: ProviderAuthState): Record<ModelMappingProvider, ProviderAuthState> {
	return {
		claude: state,
		openai: state,
		minimax: state
	};
}

let authStates = $state<Record<ModelMappingProvider, ProviderAuthState>>(createAuthStates(ProviderAuthState.Loading));

const providerLabels: Record<ModelMappingProvider, string> = {
	claude: getProviderLabel('claude'),
	openai: getProviderLabel('openai'),
	minimax: getProviderLabel('minimax')
};

function setSelectedProvider(provider: ModelMappingProvider): void {
	selectedProvider = provider;
}

function getProviderModelsCount(models: ModelMappingConfig[]): (provider: ModelMappingProvider) => number {
	return (provider) => models.filter((model) => model.provider === provider).length;
}

function applyClaudeStatus(status: ClaudeAuthStatus): void {
	claudeStatus = status;
	if (status.state === 'retry_wait') authStates.claude = ProviderAuthState.RetryWait;
	else if (status.state === 'refreshing') authStates.claude = ProviderAuthState.Loading;
	else if (status.authenticated) authStates.claude = ProviderAuthState.Authorized;
	else if (status.sessionExpired) authStates.claude = ProviderAuthState.SessionExpired;
	else authStates.claude = ProviderAuthState.NotAuthorized;
}

async function refreshAuthStates(): Promise<void> {
	authStates = createAuthStates(ProviderAuthState.Loading);

	try {
		const [claude, openai, minimax] = await Promise.all([Api.authStatus(), Api.authChatGPTStatus(), Api.authMinimaxStatus()]);
		authStates = {
			claude: ProviderAuthState.Loading,
			openai: openai.authenticated ? ProviderAuthState.Authorized : ProviderAuthState.NotAuthorized,
			minimax: minimax.authenticated ? ProviderAuthState.Authorized : ProviderAuthState.NotAuthorized
		};
		applyClaudeStatus(claude);
	} catch {
		authStates = createAuthStates(ProviderAuthState.NotAuthorized);
	}
}

export function getSettingsUiStore(): SettingsUiStore {
	const store: SettingsUiStore = {
		get claudeStatus() {
			return claudeStatus;
		},
		get selectedProvider() {
			return selectedProvider;
		},
		get authStates() {
			return authStates;
		},
		get providerLabels() {
			return providerLabels;
		},
		getProviderModelsCount,
		setSelectedProvider,
		refreshAuthStates,
		applyClaudeStatus
	};

	return store;
}
