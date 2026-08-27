import fs from 'node:fs';
import path from 'node:path';
let ts;
try { ({ default: ts } = await import('typescript')); }
catch { ({ default: ts } = await import('/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript/lib/typescript.js')); }
const root=path.resolve(process.argv[2]??'.');const files=[];
function walk(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){if(['node_modules','.next','.open-next','.git'].includes(entry.name))continue;const full=path.join(dir,entry.name);if(entry.isDirectory())walk(full);else if(/\.(ts|tsx)$/.test(entry.name)&&!entry.name.endsWith('.d.ts'))files.push(full);}}
walk(root);let failed=false;
for(const file of files){const source=fs.readFileSync(file,'utf8');const output=ts.transpileModule(source,{fileName:file,reportDiagnostics:true,compilerOptions:{jsx:ts.JsxEmit.Preserve,target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext}});for(const d of output.diagnostics??[]){if(d.category!==ts.DiagnosticCategory.Error)continue;failed=true;const m=ts.flattenDiagnosticMessageText(d.messageText,'\n');const pos=d.file&&d.start!=null?d.file.getLineAndCharacterOfPosition(d.start):null;console.error(`${file}${pos?`:${pos.line+1}:${pos.character+1}`:''} ${m}`);}}
if(failed)process.exit(1);console.log(`Syntax checked ${files.length} TypeScript/TSX files.`);
