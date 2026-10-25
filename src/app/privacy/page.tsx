import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = { title: 'Privacy policy' };

/** Where people can write to whoever runs this Resonote (set RESONOTE_CONTACT_EMAIL). */
function contactEmail(): string | undefined {
  const value = process.env.RESONOTE_CONTACT_EMAIL?.trim();
  return value ? value : undefined;
}

export default function Page() {
  const contact = contactEmail();
  return (
    <article className="page-shell rich-document" style={{ maxWidth: 760, paddingBlock: 48 }}>
      <span className="eyebrow">Resonote</span>
      <h1>Privacy policy</h1>
      <p>Resonote is a journal for close listening. This page explains what it keeps, why, and how to remove it.</p>

      <h2>What Resonote keeps</h2>
      <ul>
        <li><strong>Your email address</strong>, to send sign-in codes. It is never shown to anyone.</li>
        <li><strong>Your profile</strong>: handle, display name, bio, the genres you choose, and a profile song.</li>
        <li><strong>What you write and save</strong>: journal entries, listens, likes, collections, pins, and genre tags. Entries and collections you make public can be read by anyone; private ones and your listens only by you.</li>
        <li><strong>Reports and blocks</strong> you make, so they can be reviewed and so blocked people stay hidden from you.</li>
        <li><strong>A sign-in session</strong> (a cookie on the web, a token on iPhone) that lasts up to 30 days.</li>
      </ul>

      <h2>What&rsquo;s playing</h2>
      <p>When you ask Resonote what you&rsquo;re listening to, the song&rsquo;s title, artist, and identifiers are sent to Resonote to find it in the catalog. Apple Music is read on your iPhone. Last.fm and ListenBrainz usernames you enter stay on your device and are sent only to look up your recent plays. Identify uses Apple&rsquo;s ShazamKit, only when you tap it; Resonote never receives or keeps the audio.</p>

      <h2>Who else handles it</h2>
      <p>Resonote runs on Cloudflare, which hosts the site and its database. Sign-in codes are delivered by an email provider. Song lookups go to MusicBrainz without anything about you. Resonote has no ads, does no tracking, and doesn&rsquo;t sell or share your data.</p>

      <h2>Deleting your data</h2>
      <p>In the iPhone app, open Settings and choose Delete account. That removes your profile, everything you wrote and saved, your reports and blocks, and every session, at once and for good. Drafts live only on your device and are deleted with the account.</p>

      <h2>Questions</h2>
      {contact ? (
        <p>Write to <a href={`mailto:${contact}`}>{contact}</a>.</p>
      ) : (
        <p>Use Report in the app to flag writing or a profile. See also the <Link href="/terms">terms of use</Link>.</p>
      )}
    </article>
  );
}
