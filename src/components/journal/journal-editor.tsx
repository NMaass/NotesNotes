'use client';

import Placeholder from '@tiptap/extension-placeholder';
import StarterKit from '@tiptap/starter-kit';
import { EditorContent, useEditor } from '@tiptap/react';
import { Link2, RefreshCw, Save, Search, Sparkles } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useEffect, useMemo, useState } from 'react';
import { toast } from 'sonner';
import { useAuth } from '@/components/auth/auth-provider';
import {
  insertMusicReference,
  MusicReference as MusicReferenceExtension,
} from '@/components/journal/music-reference-extension';
import { Button } from '@/components/ui/button';
import { Chip } from '@/components/ui/chip';
import { StableSwap } from '@/components/ui/stable-swap';
import { findPotentialReferences, profileHrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type {
  CatalogEntity,
  JournalEntry,
  MusicLens,
  MusicReference as MusicReferenceData,
  RelationKind,
  RichDocument,
} from '@/lib/data/types';
import { uid } from '@/lib/utils';

const prompts = [
  'Where did this song take you?',
  'What did you notice this time?',
  'When did you first hear this?',
  'What does this take you back to?',
  'Did you used to dislike this? What changed?',
  'What does the performance do that the lyrics do not?',
  'What production choice keeps pulling your attention?',
  'What would you play immediately after this?',
  'What is hard to explain about this music?',
] as const;

const lenses: MusicLens[] = ['feeling', 'lyrics', 'composition', 'performance', 'production', 'context'];
const relationOptions: Array<{ value: RelationKind; label: string }> = [
  { value: 'mentions', label: 'linked in passing' },
  { value: 'reminds-me-of', label: 'reminds me of' },
  { value: 'pairs-with', label: 'pairs with' },
  { value: 'contrasts-with', label: 'contrasts with' },
  { value: 'influenced-by', label: 'influenced by' },
];

type TiptapNode = { type?: string; attrs?: Record<string, unknown>; content?: TiptapNode[] };
type EditorInstance = NonNullable<ReturnType<typeof useEditor>>;

function relationFromValue(value: unknown): RelationKind {
  return relationOptions.some((option) => option.value === value) ? value as RelationKind : 'mentions';
}

function lensesFromValue(value: unknown): MusicLens[] {
  if (!Array.isArray(value)) return [];
  return value.filter((lens): lens is MusicLens => lenses.includes(lens as MusicLens));
}

function referencesFromDocument(document: RichDocument): MusicReferenceData[] {
  const found: MusicReferenceData[] = [];
  const walk = (nodes: TiptapNode[] | undefined) => nodes?.forEach((node) => {
    if (node.type === 'musicReference' && node.attrs?.id && node.attrs?.entityKind) {
      found.push({
        id: typeof node.attrs.referenceId === 'string' && node.attrs.referenceId ? node.attrs.referenceId : uid('reference'),
        entityId: String(node.attrs.id),
        entityKind: node.attrs.entityKind as MusicReferenceData['entityKind'],
        label: String(node.attrs.label ?? ''),
        relation: relationFromValue(node.attrs.relation),
        lenses: lensesFromValue(node.attrs.lenses),
      });
    }
    walk(node.content);
  });
  walk(document.content as TiptapNode[] | undefined);
  return found;
}

function updateMusicReference(
  editor: EditorInstance,
  referenceId: string,
  attributes: Partial<{ relation: RelationKind; lenses: MusicLens[] }>,
) {
  const transaction = editor.state.tr;
  let changed = false;
  editor.state.doc.descendants((node, position) => {
    if (node.type.name !== 'musicReference' || String(node.attrs.referenceId) !== referenceId) return;
    transaction.setNodeMarkup(position, undefined, { ...node.attrs, ...attributes });
    changed = true;
  });
  if (changed) editor.view.dispatch(transaction);
}

function ensureMusicReferenceIds(editor: EditorInstance) {
  const transaction = editor.state.tr;
  let changed = false;
  editor.state.doc.descendants((node, position) => {
    if (node.type.name !== 'musicReference' || node.attrs.referenceId) return;
    transaction.setNodeMarkup(position, undefined, { ...node.attrs, referenceId: uid('reference') });
    changed = true;
  });
  if (changed) editor.view.dispatch(transaction);
}

export function JournalEditor({ entity, existingEntry }: { entity: CatalogEntity; existingEntry?: JournalEntry }) {
  const router = useRouter();
  const { requireAuth } = useAuth();
  const saveEntry = useResonoteStore((state) => state.saveEntry);
  const [title, setTitle] = useState(existingEntry?.title ?? '');
  const [worked, setWorked] = useState(existingEntry?.worked ?? '');
  const [didntWork, setDidntWork] = useState(existingEntry?.didntWork ?? '');
  const [showWorked, setShowWorked] = useState(Boolean(existingEntry?.worked));
  const [showDidnt, setShowDidnt] = useState(Boolean(existingEntry?.didntWork));
  const [selectedLenses, setSelectedLenses] = useState<MusicLens[]>(existingEntry?.lenses ?? []);
  const [promptIndex, setPromptIndex] = useState(1);
  const [referenceCandidates, setReferenceCandidates] = useState<CatalogEntity[]>([]);
  const [linkedReferences, setLinkedReferences] = useState<MusicReferenceData[]>(existingEntry?.references ?? []);
  const draftKey = `resonote-draft-${entity.kind}-${entity.id}`;

  const editor = useEditor({
    immediatelyRender: false,
    extensions: [
      StarterKit,
      Placeholder.configure({ placeholder: 'Write freely. Type \\ to link a song, album, artist, or genre.' }),
      MusicReferenceExtension,
    ],
    content: existingEntry?.document ?? { type: 'doc', content: [{ type: 'paragraph' }] },
    editorProps: {
      attributes: { class: 'journal-prosemirror', 'aria-label': `Journal entry about ${entity.name}` },
    },
    onUpdate: ({ editor: current }) => {
      const document = current.getJSON() as RichDocument;
      setLinkedReferences(referencesFromDocument(document));
      if (typeof window === 'undefined') return;
      const previous = JSON.parse(localStorage.getItem(draftKey) ?? '{}') as Record<string, unknown>;
      localStorage.setItem(draftKey, JSON.stringify({ ...previous, document, savedAt: Date.now() }));
    },
  });

  useEffect(() => {
    if (!editor) return;
    ensureMusicReferenceIds(editor);
  }, [editor]);

  useEffect(() => {
    if (!editor || existingEntry || typeof window === 'undefined') return;
    const raw = localStorage.getItem(draftKey);
    if (!raw) return;
    try {
      const draft = JSON.parse(raw) as {
        document?: RichDocument;
        title?: string;
        worked?: string;
        didntWork?: string;
        lenses?: MusicLens[];
      };
      if (draft.document) {
        editor.commands.setContent(draft.document, { emitUpdate: false });
        ensureMusicReferenceIds(editor);
        // eslint-disable-next-line react-hooks/set-state-in-effect -- mirror restored editor document into React state
        setLinkedReferences(referencesFromDocument(editor.getJSON() as RichDocument));
      }
      if (draft.title) setTitle(draft.title);
      if (draft.worked) {
        setWorked(draft.worked);
        setShowWorked(true);
      }
      if (draft.didntWork) {
        setDidntWork(draft.didntWork);
        setShowDidnt(true);
      }
      if (draft.lenses) setSelectedLenses(draft.lenses);
    } catch {
      localStorage.removeItem(draftKey);
    }
  }, [draftKey, editor, existingEntry]);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const raw = localStorage.getItem(draftKey);
    let previous: Record<string, unknown> = {};
    try {
      previous = JSON.parse(raw ?? '{}') as Record<string, unknown>;
    } catch {
      previous = {};
    }
    localStorage.setItem(draftKey, JSON.stringify({
      ...previous,
      title,
      worked,
      didntWork,
      lenses: selectedLenses,
      savedAt: Date.now(),
    }));
  }, [title, worked, didntWork, selectedLenses, draftKey]);

  const promptStates = useMemo(
    () => prompts.map((prompt, index) => ({ key: String(index), content: <span>{prompt}</span> })),
    [],
  );
  const currentPrompt = String(promptIndex);

  const persist = () => {
    const state = useResonoteStore.getState();
    const profile = state.data.profiles.find((candidate) => candidate.id === state.activeProfileId);
    if (!profile || !editor) return;
    const now = new Date().toISOString();
    const document = editor.getJSON() as RichDocument;
    const entry: JournalEntry = {
      id: existingEntry?.id ?? uid('entry'),
      profileId: profile.id,
      entityId: entity.id,
      entityKind: entity.kind,
      title: title.trim() || undefined,
      document,
      plainText: editor.getText().trim(),
      worked: worked.trim() || undefined,
      didntWork: didntWork.trim() || undefined,
      lenses: selectedLenses,
      references: referencesFromDocument(document),
      public: true,
      createdAt: existingEntry?.createdAt ?? now,
      updatedAt: now,
    };
    saveEntry(entry);
    localStorage.removeItem(draftKey);
    toast.success('Journal entry saved');
    router.push(profileHrefForEntity(profile, entity));
  };

  const save = () => {
    if (!editor?.getText().trim() && !worked.trim() && !didntWork.trim()) {
      toast.error('Write at least one thought first.');
      return;
    }
    if (requireAuth(persist)) persist();
  };

  const findReferences = () => {
    const currentReferences = referencesFromDocument((editor?.getJSON() ?? { type: 'doc' }) as RichDocument);
    setReferenceCandidates(
      findPotentialReferences(editor?.getText() ?? '')
        .filter((candidate) => !currentReferences.some((reference) => reference.entityId === candidate.id)),
    );
  };

  const changeReferenceRelation = (reference: MusicReferenceData, relation: RelationKind) => {
    if (!editor) return;
    updateMusicReference(editor, reference.id, { relation });
  };

  const toggleReferenceLens = (reference: MusicReferenceData, lens: MusicLens) => {
    if (!editor) return;
    const next = reference.lenses.includes(lens)
      ? reference.lenses.filter((current) => current !== lens)
      : [...reference.lenses, lens];
    updateMusicReference(editor, reference.id, { lenses: next });
  };

  return (
    <section className="journal-editor-shell">
      <div className="editor-context">
        <span className="eyebrow">Journal about {entity.kind}</span>
        <h1>{entity.name}</h1>
        <p>No score. Describe what you heard.</p>
      </div>
      <div className="prompt-panel">
        <Sparkles size={18} />
        <StableSwap active={currentPrompt} states={promptStates} axis="height" className="prompt-swap" />
        <Button
          variant="ghost"
          size="icon"
          aria-label="Another prompt"
          onClick={() => setPromptIndex((index) => (index + 1) % prompts.length)}
        >
          <RefreshCw size={18} />
        </Button>
      </div>
      <label className="field editor-title">
        <span>Optional title</span>
        <input value={title} onChange={(event) => setTitle(event.target.value)} placeholder="A thought worth naming" />
      </label>
      <div className="editor-surface"><EditorContent editor={editor} /></div>
      <div className="editor-reference-tools">
        <div className="editor-tip">
          <Link2 size={17} />
          <span>Type <kbd>\</kbd> anywhere to link music explicitly.</span>
        </div>
        <Button variant="ghost" onClick={findReferences}><Search size={17} />Find references</Button>
      </div>
      {referenceCandidates.length ? (
        <div className="suggestion-panel">
          <strong>Possible references - nothing changes until you choose one.</strong>
          <div className="chip-row">
            {referenceCandidates.map((candidate) => (
              <Chip
                key={candidate.id}
                onClick={() => {
                  if (editor) insertMusicReference(editor, candidate);
                  setReferenceCandidates((current) => current.filter((item) => item.id !== candidate.id));
                }}
              >
                {candidate.name}
              </Chip>
            ))}
          </div>
        </div>
      ) : null}
      {linkedReferences.length ? (
        <section className="linked-reference-panel" aria-label="Linked music">
          <div className="linked-reference-heading">
            <span className="eyebrow">Linked music</span>
            <p>The link is enough. Open a connection only when you want to describe why it is here.</p>
          </div>
          {linkedReferences.map((reference) => (
            <article className="linked-reference-item" key={reference.id}>
              <div>
                <span>{reference.entityKind}</span>
                <strong>{reference.label}</strong>
              </div>
              <details>
                <summary>Describe the connection</summary>
                <div className="reference-chip-section">
                  <span>Relationship</span>
                  <div className="chip-row" role="group" aria-label={`Relationship to ${reference.label}`}>
                    {relationOptions.map((option) => (
                      <Chip
                        key={option.value}
                        selected={reference.relation === option.value}
                        onClick={() => changeReferenceRelation(reference, option.value)}
                      >
                        {option.label}
                      </Chip>
                    ))}
                  </div>
                </div>
                <div className="reference-chip-section">
                  <span>What connects them?</span>
                  <div className="chip-row" role="group" aria-label={`Connection lenses for ${reference.label}`}>
                    {lenses.map((lens) => (
                      <Chip
                        key={lens}
                        selected={reference.lenses.includes(lens)}
                        onClick={() => toggleReferenceLens(reference, lens)}
                      >
                        {lens}
                      </Chip>
                    ))}
                  </div>
                </div>
              </details>
            </article>
          ))}
        </section>
      ) : null}
      <section className="editor-section">
        <h2>What kind of thought is this?</h2>
        <p className="section-note">Optional. Choose any that help someone find the angle you took.</p>
        <div className="chip-row">
          {lenses.map((lens) => (
            <Chip
              key={lens}
              selected={selectedLenses.includes(lens)}
              onClick={() => setSelectedLenses((current) =>
                current.includes(lens) ? current.filter((value) => value !== lens) : [...current, lens]
              )}
            >
              {lens}
            </Chip>
          ))}
        </div>
      </section>
      <section className="editor-section">
        <h2>Optional reflection prompts</h2>
        <div className="editor-disclosures">
          {!showWorked
            ? <Button variant="outline" onClick={() => setShowWorked(true)}>+ What worked for me</Button>
            : (
              <label className="field">
                <span>What worked for me</span>
                <textarea rows={4} value={worked} onChange={(event) => setWorked(event.target.value)} />
              </label>
            )}
          {!showDidnt
            ? <Button variant="outline" onClick={() => setShowDidnt(true)}>+ What did not work for me</Button>
            : (
              <label className="field">
                <span>What did not work for me</span>
                <textarea rows={4} value={didntWork} onChange={(event) => setDidntWork(event.target.value)} />
              </label>
            )}
        </div>
      </section>
      <div className="editor-footer">
        <span>Drafts stay on this device until you publish.</span>
        <Button size="lg" onClick={save}><Save size={18} />Publish thought</Button>
      </div>
    </section>
  );
}
