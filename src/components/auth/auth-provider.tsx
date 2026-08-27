'use client';

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { Mail } from 'lucide-react';
import { Dialog, DialogContent } from '@/components/ui/dialog';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { getActiveProfile, useResonoteStore } from '@/lib/data/store';
import { isCloudMode } from '@/lib/data/config';
import type { CloudBundle } from '@/lib/data/cloud-sync';
import type { ImportedCatalogBundle } from '@/lib/data/imported-catalog';

interface AuthContextValue {
  profile: ReturnType<typeof getActiveProfile>;
  requireAuth: (intent: () => void) => boolean;
  openAuth: () => void;
  signOut: () => void;
}

const AuthContext = createContext<AuthContextValue | null>(null);

function applyBundle(bundle: CloudBundle | null) {
  if (!bundle) return;
  const store = useResonoteStore.getState();
  const catalog: ImportedCatalogBundle = bundle.catalog ?? { artists: [], albums: [], songs: [] };
  if (catalog.artists.length || catalog.albums.length || catalog.songs.length) {
    store.importCatalogBundle(catalog);
  }
  store.signInProfile({
    profile: bundle.profile,
    likes: bundle.likes,
    entries: bundle.entries,
    listens: bundle.listens,
    collections: bundle.collections,
    pins: bundle.pins,
    genreAssertions: bundle.genreAssertions ?? [],
  });
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const activeProfileId = useResonoteStore((state) => state.activeProfileId);
  const data = useResonoteStore((state) => state.data);
  const signInDemo = useResonoteStore((state) => state.signInDemo);
  const signOutStore = useResonoteStore((state) => state.signOut);
  const profile = getActiveProfile({ activeProfileId, data });
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<'email' | 'code'>('email');
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [pending, setPending] = useState<(() => void) | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  // Restore a cloud session on load. Local profiles persist through the store.
  useEffect(() => {
    if (!isCloudMode || profile) return;
    let cancelled = false;
    void (async () => {
      try {
        const { loadSessionBundle } = await import('@/lib/data/cloud-sync');
        const bundle = await loadSessionBundle();
        if (!cancelled && bundle) applyBundle(bundle);
      } catch (error) {
        if (!cancelled) console.error('Could not restore the Resonote session.', error);
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- run once on mount
  }, []);

  const closeAndContinue = useCallback(() => {
    setOpen(false);
    setStep('email');
    setCode('');
    const action = pending;
    setPending(null);
    queueMicrotask(() => action?.());
  }, [pending]);

  const finishDemo = useCallback(() => {
    signInDemo();
    closeAndContinue();
  }, [closeAndContinue, signInDemo]);

  const sendCode = async () => {
    setError('');
    if (!email.includes('@')) {
      setError('Enter an email address.');
      return;
    }
    if (!isCloudMode) {
      setStep('code');
      return;
    }
    setBusy(true);
    try {
      const response = await fetch('/api/auth/request-code', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });
      const body = await response.json() as { ok?: boolean; error?: string; devCode?: string };
      if (!response.ok || !body.ok) throw new Error(body.error ?? 'Could not send a code.');
      if (body.devCode) {
        console.info(`[Resonote dev-mode] sign-in code for ${email}: ${body.devCode}`);
        toast.info(`Dev mode — no mail provider configured. Your code is ${body.devCode}.`, { duration: 15000 });
      }
      setStep('code');
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : 'Could not send a code.');
    } finally {
      setBusy(false);
    }
  };

  const verify = async () => {
    setError('');
    if (!isCloudMode) {
      if (code !== '000000') {
        setError('In demo mode, use 000000.');
        return;
      }
      finishDemo();
      return;
    }
    setBusy(true);
    try {
      const response = await fetch('/api/auth/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, code }),
      });
      const body = await response.json() as { ok?: boolean; error?: string; bundle?: CloudBundle | null };
      if (!response.ok || !body.ok) throw new Error(body.error ?? 'The code could not be verified.');
      applyBundle(body.bundle ?? null);
      closeAndContinue();
    } catch (verifyError) {
      setError(verifyError instanceof Error ? verifyError.message : 'The code could not be verified.');
    } finally {
      setBusy(false);
    }
  };

  const value = useMemo<AuthContextValue>(() => ({
    profile,
    requireAuth: (intent) => {
      if (profile) return true;
      setPending(() => intent);
      setOpen(true);
      return false;
    },
    openAuth: () => {
      setPending(null);
      setOpen(true);
    },
    signOut: () => {
      if (isCloudMode) void fetch('/api/auth/signout', { method: 'POST' });
      signOutStore();
    },
  }), [profile, signOutStore]);

  return (
    <AuthContext.Provider value={value}>
      {children}
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent
          title={step === 'email' ? 'Keep your place' : 'Check your email'}
          description={step === 'email'
            ? 'Sign in without a password. Your current action will continue afterward.'
            : `Enter the six-digit code sent to ${email}.`}
        >
          <div className="auth-form">
            {step === 'email' ? (
              <label className="field">
                <span>Email</span>
                <div className="input-with-icon">
                  <Mail size={18} />
                  <input
                    autoFocus
                    type="email"
                    inputMode="email"
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                    onKeyDown={(event) => { if (event.key === 'Enter') void sendCode(); }}
                    placeholder="you@example.com"
                  />
                </div>
              </label>
            ) : (
              <label className="field">
                <span>One-time code</span>
                <input
                  autoFocus
                  className="otp-input"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  value={code}
                  onChange={(event) => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))}
                  onKeyDown={(event) => { if (event.key === 'Enter') void verify(); }}
                  placeholder="000000"
                />
              </label>
            )}
            {!isCloudMode
              ? <p className="demo-note">Demo mode: use <strong>000000</strong>. No email is sent.</p>
              : null}
            {error
              ? <p className="form-error" role="alert">{error}</p>
              : <div className="form-error form-error--reserved" aria-hidden="true">&nbsp;</div>}
            <Button size="lg" disabled={busy} onClick={() => void (step === 'email' ? sendCode() : verify())}>
              {busy ? 'Working...' : step === 'email' ? 'Send code' : 'Continue'}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const value = useContext(AuthContext);
  if (!value) throw new Error('useAuth must be used inside AuthProvider');
  return value;
}
