import { PersistentPlayer } from '@/components/player/persistent-player';
import { SiteHeader } from '@/components/shell/site-header';
export function AppShell({ children }: { children: React.ReactNode }) {
  return <><SiteHeader /><main id="main-content">{children}</main><PersistentPlayer /></>;
}
