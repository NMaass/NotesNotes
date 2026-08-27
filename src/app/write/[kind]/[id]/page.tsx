import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { JournalEditor } from '@/components/journal/journal-editor';
import { getEntity } from '@/lib/data/selectors';
import type { EntityKind } from '@/lib/data/types';
export async function generateMetadata({params}:{params:Promise<{kind:string;id:string}>}):Promise<Metadata>{const{kind,id}=await params;const entity=['artist','album','song','genre'].includes(kind)?getEntity(kind as EntityKind,id):undefined;return entity?{title:`Write about ${entity.name}`}:{}}
export default async function Page({params}:{params:Promise<{kind:string;id:string}>}){const{kind,id}=await params;if(!['artist','album','song','genre'].includes(kind))notFound();const entity=getEntity(kind as EntityKind,id);if(!entity)notFound();return <div className="page-shell write-page"><JournalEditor entity={entity}/></div>;}
