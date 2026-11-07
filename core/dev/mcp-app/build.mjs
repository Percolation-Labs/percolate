import {build} from 'esbuild';
import {readFile,writeFile} from 'node:fs/promises';
const root=new URL('../../',import.meta.url),staticDir=new URL('percolate_core/ui/static/',root);
const result=await build({entryPoints:[new URL('./app.js',import.meta.url).pathname],bundle:true,write:false,format:'esm',minify:true,legalComments:'inline',target:'es2022'});
const css=(await Promise.all(['theme.css','result-canvas.css'].map(name=>readFile(new URL(name,staticDir),'utf8')))).join('\n');
const html=`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Percolate Canvas</title><style>${css}\nbody{display:block;min-width:0;padding:10px;background:var(--paper);height:auto}main{min-width:0}header.canvas-commandbar{margin:0 0 8px;min-height:24px}.network-svg{height:440px;min-height:300px}[role=alert]:empty{display:none}</style></head><body><script type="module">${result.outputFiles[0].text.replaceAll('</script','<\\/script')}</script></body></html>`;
await writeFile(new URL('canvas-app.html',staticDir),html);
console.log('Built self-contained canvas-app.html');
