export type LauncherTransportName = 'ungate' | 'cliproxyapi' | 'omniroute';
export type LauncherLogLevel = 'Full' | 'Standard' | 'Compact' | 'Minimal' | 'Off' | 'Errors';
export type LauncherOperationStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled' | 'interrupted';

export interface LauncherFieldPatch {
	set?: Record<string, unknown>;
	unset?: string[];
	registryId: string;
	expectedRevision: string;
	profileId: 'default';
}

export interface LauncherModelState {
	registryId: string;
	inTemplate: boolean;
	displayName: string;
	upstreamModel: string | null;
	nativeUpstream: string;
	requestModel: string;
	transport: string;
	providerName: string;
	contextWindow: number;
	contextLabel: string;
	image: boolean;
	original: boolean;
	reasoningDefault: string;
	reasoningLevels: string[];
	inPicker: boolean;
	endpoint: string;
	adapter: string | null;
	bridgeRequired: boolean;
	credentialAvailable: boolean;
	credentialSource: string;
	capabilities: Record<string, unknown>;
	explicit: Record<string, unknown>;
	provenance: Record<string, string>;
	revisions: { version: string; capabilities: string; prefix: string; remove: string };
}

export interface LauncherState {
	profileId: 'default';
	betaHome: string;
	definitionError: string | null;
	picker: {
		slugs: string[];
		capacity: number;
		revision: string;
		corrupt: boolean;
		message: string | null;
		usingDefault: boolean;
	};
	memory: {
		saved: { enabled: boolean; provider: string; model: string } | null;
		revision: string;
		corrupt: boolean;
		message: string | null;
		defaults: { enabled: boolean; provider: string; model: string };
	};
	logging: { level: LauncherLogLevel | null; revision: string; corrupt: boolean; message: string | null; usingDefault: boolean };
	registry: { revision: string; corrupt: boolean; message: string | null; notice: string | null };
	templates: { revision: string; models: { registryId: string; displayName: string }[] };
	overrides: { corrupt: boolean; message: string | null };
	models: LauncherModelState[];
	launch: {
		entryPoint: string;
		agentScript: string;
		fallbackModel: string;
		logLevels: LauncherLogLevel[];
		reasoningLevels: string[];
	};
	activeOperation: LauncherOperation | null;
}

export interface LauncherOperation {
	id: string;
	requestId: string;
	kind: string;
	status: LauncherOperationStatus;
	stage: string | null;
	message: string | null;
	registryIds: string[];
	startedAt: string;
	finishedAt: string | null;
	deadlineAt: string;
	reportId: string | null;
	exitCode: number | null;
}

export interface LauncherFailure {
	code: string;
	message: string;
	currentRevision?: string;
	snapshot?: LauncherState;
	fieldErrors?: { field?: string; message?: string }[];
}
