'use client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import * as Tooltip from '@radix-ui/react-tooltip';
import { useState } from 'react';
import { Toaster } from 'sonner';
import { AuthProvider } from '@/components/auth/auth-provider';

export function Providers({ children }: { children: React.ReactNode }) {
  const [client] = useState(() => new QueryClient({ defaultOptions: { queries: { staleTime: 5 * 60_000, refetchOnWindowFocus: false } } }));
  return (
    <QueryClientProvider client={client}>
      <Tooltip.Provider delayDuration={300}>
        <AuthProvider>{children}</AuthProvider>
        <Toaster position="bottom-center" richColors />
      </Tooltip.Provider>
    </QueryClientProvider>
  );
}
