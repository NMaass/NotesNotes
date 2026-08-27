import Link from 'next/link';
export default function NotFound(){return <div className="page-shell error-page"><span className="eyebrow">404</span><h1>That page is not in this collection.</h1><p>The link may point to music Resonote has not cached yet.</p><Link className="button button--solid button--lg" href="/">Return home</Link></div>;}
