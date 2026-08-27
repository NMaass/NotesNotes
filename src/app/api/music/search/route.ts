import { NextRequest, NextResponse } from 'next/server';
import { searchMusicBrainz } from '@/lib/music/musicbrainz';

export const runtime = 'nodejs';

export async function GET(request: NextRequest) {
  const query = request.nextUrl.searchParams.get('q')?.trim() ?? '';
  const requested = request.nextUrl.searchParams.get('kind');
  const kind = requested === 'artist' || requested === 'album' || requested === 'song' ? requested : 'song';
  if (query.length < 2) return NextResponse.json({ results: [] });
  try {
    const results = await searchMusicBrainz(query, kind);
    return NextResponse.json({ results });
  } catch (error) {
    return NextResponse.json({ results: [], error: error instanceof Error ? error.message : 'Search unavailable' }, { status: 502 });
  }
}
