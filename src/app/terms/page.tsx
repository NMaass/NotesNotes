import type { Metadata } from 'next';
import Link from 'next/link';

export const metadata: Metadata = { title: 'Terms of use' };

function contactEmail(): string | undefined {
  const value = process.env.RESONOTE_CONTACT_EMAIL?.trim();
  return value ? value : undefined;
}

export default function Page() {
  const contact = contactEmail();
  return (
    <article className="page-shell rich-document" style={{ maxWidth: 760, paddingBlock: 48 }}>
      <span className="eyebrow">Resonote</span>
      <h1>Terms of use</h1>
      <p>Resonote is a shared journal about music. Using it means agreeing to these terms.</p>

      <h2>No objectionable content, no abuse</h2>
      <p>Resonote has no tolerance for objectionable content or abusive behavior. Don&rsquo;t post anything hateful, harassing, threatening, sexually explicit, or illegal, don&rsquo;t spam, and don&rsquo;t impersonate anyone. Write about the music, not to hurt people.</p>

      <h2>Reporting and blocking</h2>
      <p>Anyone signed in can report an entry or a profile, and block a person so their writing is hidden from them everywhere. Reports are reviewed, and writing or accounts that break these terms are removed.</p>

      <h2>Your writing</h2>
      <p>What you write stays yours. By making an entry or collection public, you let Resonote show it to other people on the site and in the app. You can make it private or delete it at any time, and you can delete your account in the app&rsquo;s Settings.</p>

      <h2>The catalog</h2>
      <p>Music information comes from MusicBrainz and from listeners. It may be incomplete or wrong; corrections happen through the catalog, not through ratings.</p>

      <h2>Changes and contact</h2>
      <p>These terms may change; the version on this page is the one that applies. Read how your data is handled in the <Link href="/privacy">privacy policy</Link>.</p>
      {contact ? <p>Questions: <a href={`mailto:${contact}`}>{contact}</a>.</p> : null}
    </article>
  );
}
