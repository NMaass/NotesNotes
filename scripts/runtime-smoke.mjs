import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
let ts;
try { ({ default: ts } = await import('typescript')); }
catch { ({ default: ts } = await import('/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript/lib/typescript.js')); }
const root=process.cwd();const out=path.join(root,'.audit/runtime');fs.rmSync(out,{recursive:true,force:true});
const files=['src/lib/data/types.ts','src/lib/data/catalog.ts','src/lib/utils.ts','src/lib/data/selectors.ts'];
for(const relative of files){const sourcePath=path.join(root,relative);let source=fs.readFileSync(sourcePath,'utf8');source=source.replaceAll("'@/lib/data/catalog'","'./catalog'").replaceAll("'@/lib/data/types'","'./types'").replaceAll("'@/lib/utils'","'../utils'");const output=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText;const outputPath=path.join(out,relative.replace(/^src\//,'').replace(/\.ts$/,'.js'));fs.mkdirSync(path.dirname(outputPath),{recursive:true});fs.writeFileSync(outputPath,output);}
fs.mkdirSync(path.join(out,'node_modules/clsx'),{recursive:true});fs.writeFileSync(path.join(out,'node_modules/clsx/index.js'),"exports.clsx=(...v)=>v.flat(Infinity).filter(Boolean).join(' ');");
fs.mkdirSync(path.join(out,'node_modules/tailwind-merge'),{recursive:true});fs.writeFileSync(path.join(out,'node_modules/tailwind-merge/index.js'),"exports.twMerge=(v)=>v;");
const {createRequire}=await import('node:module');const req=createRequire(path.join(out,'smoke.cjs'));
const selectors=req('./lib/data/selectors.js');const catalog=req('./lib/data/catalog.js');const utils=req('./lib/utils.js');
assert.equal(selectors.getEntityByPath(['nirvana','nevermind','lithium']).id,'40000000-0000-0000-0000-000000000001');
assert.ok(selectors.searchLocalCatalog('mbv').some((result)=>result.entity.id==='20000000-0000-0000-0000-000000000002'));
const maya=catalog.seedDemoData.profiles.find((profile)=>profile.id==='50000000-0000-0000-0000-000000000001');
const pumpkins=selectors.getProfileLibrary(maya,catalog.seedDemoData).find((group)=>group.artist.id==='20000000-0000-0000-0000-000000000003');
assert.equal(pumpkins.artistLiked,false);assert.equal(pumpkins.albums[0].albumLiked,false);assert.deepEqual(pumpkins.albums[0].songs.map((song)=>song.id),['40000000-0000-0000-0000-000000000003']);
const vig=selectors.getCollaboratorInsights(maya,catalog.seedDemoData).find((item)=>item.collaboratorKey==='person-butch-vig');
assert.deepEqual([...vig.songIds].sort(),['40000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000003']);assert.equal(vig.artistIds.length,2);
assert.ok(selectors.getReferencedConnections('40000000-0000-0000-0000-000000000001',catalog.seedDemoData).some((item)=>item.entity.id==='40000000-0000-0000-0000-000000000002'));
const tagged=JSON.parse(JSON.stringify(catalog.seedDemoData));tagged.genreAssertions.push({id:'f1000000-0000-0000-0000-000000000001',entityId:'40000000-0000-0000-0000-000000000001',entityKind:'song',genreId:'10000000-0000-0000-0000-000000000004',source:'user',createdBy:maya.id,votes:1});
const ambient=selectors.getGenresForEntity('40000000-0000-0000-0000-000000000001',tagged).find((item)=>item.genre.id==='10000000-0000-0000-0000-000000000004');assert.equal(ambient.source,'user');assert.equal(ambient.votes,1);
assert.equal(utils.slugify('Hurry Up, We’re Dreaming'),'hurry-up-were-dreaming');assert.equal(utils.formatDuration(257000),'4:17');
console.log('Runtime catalog and selector smoke checks passed.');
