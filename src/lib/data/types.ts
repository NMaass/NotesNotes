export type EntityKind = 'artist' | 'album' | 'song' | 'genre';
export type MusicLens = 'feeling' | 'lyrics' | 'composition' | 'performance' | 'production' | 'context';
export type RelationKind = 'reminds-me-of' | 'influenced-by' | 'pairs-with' | 'contrasts-with' | 'mentions';
interface EntityBase { id: string; kind: EntityKind; name: string; slug: string; imageUrl?: string; musicbrainzId?: string; summary?: string }
export interface Artist extends EntityBase { kind: 'artist'; sortName?: string; country?: string }
export interface Album extends EntityBase { kind: 'album'; artistId: string; year?: number; releaseGroupType?: string }
export interface Song extends EntityBase { kind: 'song'; artistId: string; albumId?: string; trackNumber?: number; durationMs?: number; spotifyId?: string; youtubeId?: string; isBonusTrack?: boolean }
export interface Genre extends EntityBase { kind: 'genre'; description?: string }
export type CatalogEntity = Artist | Album | Song | Genre;
export interface EntityGenre { id?: string; entityId: string; entityKind?: EntityKind; genreId: string; source: 'catalog' | 'community' | 'user'; createdBy?: string; votes?: number }
export interface SongCredit { id: string; songId: string; name: string; role: string; collaboratorKey: string; artistId?: string; sourceLabel: string; sourceUrl?: string }
export interface SongFact { id: string; songId: string; label: string; value: string; sourceLabel: string; sourceUrl?: string; confidence: 'catalog' | 'estimated' | 'community' }
export interface Profile { id: string; handle: string; displayName: string; bio: string; avatarUrl?: string; profileSongId?: string; genreIds: string[] }
export interface Like { id: string; profileId: string; entityId: string; entityKind: EntityKind; clientVersion: number; createdAt: string }
export interface MusicReference { id: string; entityId: string; entityKind: EntityKind; label: string; relation: RelationKind; lenses: MusicLens[]; start?: number; end?: number }
export type RichDocument = { type: 'doc'; content?: Array<Record<string, unknown>> };
export interface JournalEntry { id: string; profileId: string; entityId: string; entityKind: EntityKind; title?: string; document: RichDocument; plainText: string; worked?: string; didntWork?: string; lenses: MusicLens[]; references: MusicReference[]; public: boolean; createdAt: string; updatedAt: string }
export interface ListenLog { id: string; profileId: string; songId: string; moods: string[]; note?: string; listenedAt: string }
export interface CollectionItem { id: string; entityId: string; entityKind: EntityKind; note?: string; position: number }
export interface Collection { id: string; profileId: string; name: string; slug: string; description: string; public: boolean; items: CollectionItem[]; createdAt: string; updatedAt: string }
export interface ProfilePin { id: string; profileId: string; targetType: 'entity' | 'entry' | 'collection'; targetId: string; position: number }
export interface DemoData { profiles: Profile[]; likes: Like[]; entries: JournalEntry[]; listens: ListenLog[]; collections: Collection[]; pins: ProfilePin[]; genreAssertions: EntityGenre[] }
export interface ProfileBundle { profile: Profile; likes: Like[]; entries: JournalEntry[]; listens: ListenLog[]; collections: Collection[]; pins: ProfilePin[]; genreAssertions: EntityGenre[] }
export interface SearchResult { entity: CatalogEntity; subtitle: string; source: 'local' | 'musicbrainz' }
