// Run the maintained renderer and compact-cell checks.
const {execFileSync}=require('node:child_process');
for(const file of ['dev/check-result-canvas.cjs','dev/check-table-cells.cjs'])execFileSync(process.execPath,[file],{stdio:'inherit'});
