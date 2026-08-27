import type { Metadata } from 'next';
import { ImportedEntityGate } from '@/components/entity/imported-entity-gate';
import { EntityPage } from '@/components/entity/entity-page';
import { getEntityByPath, subtitleForEntity } from '@/lib/data/selectors';
export async function generateMetadata({params}:{params:Promise<{segments:string[]}>}):Promise<Metadata>{const{segments}=await params;const entity=getEntityByPath(segments);return entity?{title:entity.name,description:entity.summary??subtitleForEntity(entity)}:{};}
export default async function Page({params}:{params:Promise<{segments:string[]}>}){const{segments}=await params;const entity=getEntityByPath(segments);if(entity)return <EntityPage entity={entity}/>;
  // Not in the static catalog: it may be an import stored on this device.
  return <ImportedEntityGate segments={segments}/>;}
