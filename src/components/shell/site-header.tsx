'use client';

import * as DialogPrimitive from '@radix-ui/react-dialog';
import { BookOpen, Headphones, Heart, Home, Library, Menu, Search, UserRound, X } from 'lucide-react';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { useAuth } from '@/components/auth/auth-provider';
import { GlobalSearch } from '@/components/search/global-search';
import { Button } from '@/components/ui/button';

export function SiteHeader() {
  const [searchOpen, setSearchOpen] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const { profile, signOut } = useAuth();

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      const typing = target?.matches('input, textarea, select, [contenteditable="true"]');
      if (typing) return;
      event.preventDefault();
      setSearchOpen(true);
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  return (
    <>
      <header className="site-header">
        <div className="site-header-inner">
          <Link href="/" className="brand" aria-label="Resonote home">
            <img src="/logo-mark.svg" alt="" />
            <span>Resonote</span>
          </Link>
          <button className="header-search" type="button" onClick={() => setSearchOpen(true)}>
            <Search size={18} />
            <span>Search music...</span>
            <kbd>/</kbd>
          </button>
          <nav className="desktop-nav" aria-label="Primary">
            <Link href="/">Discover</Link>
            {profile ? <Link href={`/@${profile.handle}`}>Your profile</Link> : null}
            {profile
              ? <Button variant="ghost" onClick={signOut}>Sign out</Button>
              : <Link className="button button--ghost button--md" href="/join">Join</Link>}
          </nav>
          <Button
            className="mobile-search-button"
            variant="ghost"
            size="icon"
            aria-label="Search"
            onClick={() => setSearchOpen(true)}
          >
            <Search />
          </Button>
          <Button
            className="mobile-menu-button"
            variant="ghost"
            size="icon"
            aria-label="Open menu"
            onClick={() => setMenuOpen(true)}
          >
            <Menu />
          </Button>
        </div>
      </header>
      <GlobalSearch open={searchOpen} onOpenChange={setSearchOpen} />
      <DialogPrimitive.Root open={menuOpen} onOpenChange={setMenuOpen}>
        <DialogPrimitive.Portal>
          <DialogPrimitive.Overlay className="dialog-overlay" />
          <DialogPrimitive.Content className="mobile-drawer" aria-describedby={undefined}>
            <div className="mobile-drawer-header">
              <DialogPrimitive.Title>Menu</DialogPrimitive.Title>
              <DialogPrimitive.Close asChild>
                <Button variant="ghost" size="icon" aria-label="Close menu"><X /></Button>
              </DialogPrimitive.Close>
            </div>
            <nav className="mobile-nav" onClick={() => setMenuOpen(false)}>
              <Link href="/"><Home />Discover</Link>
              {profile ? (
                <>
                  <Link href={`/@${profile.handle}`}><UserRound />Profile</Link>
                  <Link href={`/@${profile.handle}#journal`}><BookOpen />Journal</Link>
                  <Link href={`/@${profile.handle}#listens`}><Headphones />Listens</Link>
                  <Link href={`/@${profile.handle}#library`}><Library />Library</Link>
                  <Link href={`/@${profile.handle}#collections`}><Heart />Collections</Link>
                </>
              ) : null}
            </nav>
            <div className="mobile-drawer-action">
              {profile
                ? <Button size="lg" onClick={() => { setMenuOpen(false); signOut(); }}>Sign out</Button>
                : <Link className="button button--solid button--lg" href="/join" onClick={() => setMenuOpen(false)}>Join Resonote</Link>}
            </div>
          </DialogPrimitive.Content>
        </DialogPrimitive.Portal>
      </DialogPrimitive.Root>
    </>
  );
}
