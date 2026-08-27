import { describe, expect, it } from 'vitest';
import { seedDemoData } from '@/lib/data/catalog';
import { getCollaboratorInsights, getEntityByPath, getGenresForEntity, getProfileLibrary, getReferencedConnections, searchLocalCatalog } from '@/lib/data/selectors';

describe('catalog selectors', () => {
  it('resolves artist / release-group / recording URLs', () => expect(getEntityByPath(['nirvana','nevermind','lithium'])?.id).toBe('40000000-0000-0000-0000-000000000001'));
  it('supports a human alias', () => expect(searchLocalCatalog('mbv').some((result) => result.entity.id === '20000000-0000-0000-0000-000000000002')).toBe(true));
  it('does not imply an album is liked when only one song is liked', () => {
    const profile = seedDemoData.profiles.find((candidate) => candidate.id === '50000000-0000-0000-0000-000000000001')!;
    const pumpkins = getProfileLibrary(profile, seedDemoData).find((group) => group.artist.id === '20000000-0000-0000-0000-000000000003')!;
    expect(pumpkins.artistLiked).toBe(false);
    expect(pumpkins.albums[0].albumLiked).toBe(false);
    expect(pumpkins.albums[0].songs.map((song) => song.id)).toEqual(['40000000-0000-0000-0000-000000000003']);
  });
  it('only calls out collaborator patterns across multiple artists', () => {
    const profile = seedDemoData.profiles.find((candidate) => candidate.id === '50000000-0000-0000-0000-000000000001')!;
    const vig = getCollaboratorInsights(profile, seedDemoData).find((item) => item.collaboratorKey === 'person-butch-vig')!;
    expect([...vig.songIds].sort()).toEqual(['40000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000003']);
    expect(vig.artistIds).toHaveLength(2);
  });
  it('derives explicit reference connections without collaborative filtering', () => expect(getReferencedConnections('40000000-0000-0000-0000-000000000001', seedDemoData).some((item) => item.entity.id === '40000000-0000-0000-0000-000000000002')).toBe(true));
  it('keeps a personal genre assertion attributable while combining it for display', () => {
    const data = JSON.parse(JSON.stringify(seedDemoData));
    data.genreAssertions.push({
      id: 'f1000000-0000-0000-0000-000000000001',
      entityId: '40000000-0000-0000-0000-000000000001',
      entityKind: 'song',
      genreId: '10000000-0000-0000-0000-000000000004',
      source: 'user',
      createdBy: '50000000-0000-0000-0000-000000000001',
      votes: 1,
    });
    const ambient = getGenresForEntity('40000000-0000-0000-0000-000000000001', data)
      .find((item) => item.genre.id === '10000000-0000-0000-0000-000000000004');
    expect(ambient).toMatchObject({ source: 'user', votes: 1 });
  });
});
