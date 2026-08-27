const mode = process.env.NEXT_PUBLIC_DATA_MODE === 'cloud' ? 'cloud' : 'demo';
const names = ['MUSICBRAINZ_CONTACT_EMAIL', 'RESEND_API_KEY', 'AUTH_EMAIL_FROM'];
console.log('Resonote environment check');
console.log(`DATA ${mode}`);
for (const name of names) console.log(`${process.env[name] ? 'OK ' : '-- '} ${name}`);
if (mode === 'cloud') {
  console.log('\nCloud mode stores accounts and imports in Cloudflare D1 through server routes.');
  console.log('No client-side database credentials exist. RESEND_API_KEY enables real OTP email; without it codes print to the server log.');
} else {
  console.log('\nNo values are required for demo mode. Demo OTP: 000000');
}
