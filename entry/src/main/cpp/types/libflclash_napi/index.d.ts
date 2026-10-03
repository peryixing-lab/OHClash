export const launch: (homeDir: string, secret: string) => string;
export const startTun: (fd: number) => boolean;
export const getTunError: () => string;
export const launchAsync: (homeDir: string, secret: string) => Promise<string>;
export const startTunAsync: (fd: number) => Promise<boolean>;
export const stop: () => void;
export const stopAsync: () => Promise<void>;
export const invoke: (input: string) => string;

export const inspectProfile: (content: string) => Promise<string>;

export const testProfileDelay: (content: string, name: string) => Promise<string>;

export const beginDelayJob: (content: string, names: string) => string;
export const pollDelayJob: (id: string) => string;
export const cancelDelayJob: (id: string) => void;
