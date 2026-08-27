export type DataMode = 'demo' | 'cloud';

export const dataMode: DataMode = process.env.NEXT_PUBLIC_DATA_MODE === 'cloud' ? 'cloud' : 'demo';

/** Cloud mode needs no client-side credentials: D1 is reached through our API routes. */
export const isCloudMode = dataMode === 'cloud';
