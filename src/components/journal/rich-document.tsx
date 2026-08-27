import type { ReactNode } from 'react';
import { MusicReferenceLink } from '@/components/music/music-reference-hover';
import type { RichDocument } from '@/lib/data/types';

type Node = { type?: string; text?: string; attrs?: Record<string, unknown>; marks?: Array<{ type?: string }>; content?: Node[] };

function renderNodes(nodes: Node[] | undefined, keyPrefix = 'n'): ReactNode[] {
  return (nodes ?? []).map((node, index) => {
    const key = `${keyPrefix}-${index}`;
    if (node.type === 'text') {
      let value: ReactNode = node.text ?? '';
      for (const mark of node.marks ?? []) {
        if (mark.type === 'bold') value = <strong>{value}</strong>;
        if (mark.type === 'italic') value = <em>{value}</em>;
        if (mark.type === 'code') value = <code>{value}</code>;
      }
      return <span key={key}>{value}</span>;
    }
    if (node.type === 'musicReference') return <MusicReferenceLink key={key} entityId={String(node.attrs?.id ?? '')} label={String(node.attrs?.label ?? 'music')} />;
    const children = renderNodes(node.content, key);
    if (node.type === 'paragraph') return <p key={key}>{children.length ? children : <br />}</p>;
    if (node.type === 'heading') { const level = Number(node.attrs?.level ?? 3); return level === 2 ? <h2 key={key}>{children}</h2> : <h3 key={key}>{children}</h3>; }
    if (node.type === 'bulletList') return <ul key={key}>{children}</ul>;
    if (node.type === 'orderedList') return <ol key={key}>{children}</ol>;
    if (node.type === 'listItem') return <li key={key}>{children}</li>;
    if (node.type === 'blockquote') return <blockquote key={key}>{children}</blockquote>;
    if (node.type === 'hardBreak') return <br key={key} />;
    return <span key={key}>{children}</span>;
  });
}

export function RichDocumentView({ document }: { document: RichDocument }) {
  return <div className="rich-document">{renderNodes(document.content as Node[] | undefined)}</div>;
}
