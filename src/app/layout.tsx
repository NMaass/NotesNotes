import type { Metadata, Viewport } from 'next';
import { AppShell } from '@/components/shell/app-shell';
import { Providers } from '@/components/providers';
import './globals.css';
import 'tippy.js/dist/tippy.css';
export const metadata: Metadata = { title:{default:'Resonote — a journal for close listening',template:'%s · Resonote'},description:'Write about what music evokes, how it works, and what it reminds you of—without reducing it to a rating.',metadataBase:new URL(process.env.NEXT_PUBLIC_SITE_URL??'http://localhost:3000'),openGraph:{title:'Resonote',description:'A journal for close listening.',type:'website'},icons:{icon:'/favicon.svg'} };
export const viewport: Viewport = {width:'device-width',initialScale:1,themeColor:'#101113'};
export default function RootLayout({children}:Readonly<{children:React.ReactNode}>){return <html lang="en"><body><a className="skip-link" href="#main-content">Skip to content</a><Providers><AppShell>{children}</AppShell></Providers></body></html>;}
