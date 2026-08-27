import { Mention } from '@tiptap/extension-mention';
import { ReactRenderer } from '@tiptap/react';
import type { SuggestionOptions } from '@tiptap/suggestion';
import tippy, { type Instance } from 'tippy.js';
import { MusicReferenceMenu, type MusicReferenceMenuHandle } from '@/components/journal/music-reference-menu';
import { searchLocalCatalog } from '@/lib/data/selectors';
import type { CatalogEntity, SearchResult } from '@/lib/data/types';
import { uid } from '@/lib/utils';

const suggestion: Omit<SuggestionOptions<SearchResult>, 'editor'> = {
  char: '\\',
  allowSpaces: true,
  startOfLine: false,
  items: ({ query }) => searchLocalCatalog(query, 8),
  command: ({ editor, range, props }) => {
    const entity = (props as unknown as SearchResult).entity;
    editor.chain().focus().insertContentAt(range, [
      { type: 'musicReference', attrs: { referenceId: uid('reference'), id: entity.id, label: entity.name, entityKind: entity.kind, relation: 'mentions', lenses: [] } },
      { type: 'text', text: ' ' }
    ]).run();
  },
  render: () => {
    let component: ReactRenderer<MusicReferenceMenuHandle> | null = null;
    let popup: Instance | null = null;
    return {
      onStart: (props) => {
        component = new ReactRenderer(MusicReferenceMenu, { props, editor: props.editor });
        if (!props.clientRect) return;
        popup = tippy(document.body, {
          getReferenceClientRect: props.clientRect as () => DOMRect,
          appendTo: () => document.body,
          content: component.element,
          showOnCreate: true,
          interactive: true,
          trigger: 'manual',
          placement: 'bottom-start',
          maxWidth: 'none'
        }) as Instance;
      },
      onUpdate: (props) => {
        component?.updateProps(props);
        if (props.clientRect) popup?.setProps({ getReferenceClientRect: props.clientRect as () => DOMRect });
      },
      onKeyDown: (props) => {
        if (props.event.key === 'Escape') { popup?.hide(); return true; }
        return component?.ref?.onKeyDown(props.event) ?? false;
      },
      onExit: () => { popup?.destroy(); component?.destroy(); popup = null; component = null; }
    };
  }
};

export const MusicReference = Mention.extend({
  name: 'musicReference',
  addAttributes() {
    return {
      referenceId: { default: null, parseHTML: (element: HTMLElement) => element.getAttribute('data-reference-id'), renderHTML: (attrs: Record<string, any>) => ({ 'data-reference-id': attrs.referenceId }) },
      id: { default: null, parseHTML: (element: HTMLElement) => element.getAttribute('data-music-id'), renderHTML: (attrs: Record<string, any>) => ({ 'data-music-id': attrs.id }) },
      label: { default: null, parseHTML: (element: HTMLElement) => element.getAttribute('data-label'), renderHTML: (attrs: Record<string, any>) => ({ 'data-label': attrs.label }) },
      entityKind: { default: null, parseHTML: (element: HTMLElement) => element.getAttribute('data-entity-kind'), renderHTML: (attrs: Record<string, any>) => ({ 'data-entity-kind': attrs.entityKind }) },
      relation: { default: 'mentions', parseHTML: (element: HTMLElement) => element.getAttribute('data-relation') ?? 'mentions', renderHTML: (attrs: Record<string, any>) => ({ 'data-relation': attrs.relation }) },
      lenses: { default: [], parseHTML: (element: HTMLElement) => (element.getAttribute('data-lenses') ?? '').split(',').filter(Boolean), renderHTML: (attrs: Record<string, any>) => ({ 'data-lenses': Array.isArray(attrs.lenses) ? attrs.lenses.join(',') : '' }) }
    };
  },
  parseHTML() { return [{ tag: 'span[data-music-reference]' }]; },
  renderHTML({ node, HTMLAttributes }: { node: any; HTMLAttributes: any }) { return ['span', { ...HTMLAttributes, 'data-music-reference': '', class: 'music-reference-inline' }, node.attrs.label ?? node.attrs.id]; },
  renderText({ node }: { node: any }) { return node.attrs.label ?? node.attrs.id; }
}).configure({ suggestion: suggestion as SuggestionOptions<SearchResult> });

export function insertMusicReference(editor: { chain: () => any }, entity: CatalogEntity) {
  editor.chain().focus().insertContent([
    { type: 'musicReference', attrs: { referenceId: uid('reference'), id: entity.id, label: entity.name, entityKind: entity.kind, relation: 'mentions', lenses: [] } },
    { type: 'text', text: ' ' }
  ]).run();
}
