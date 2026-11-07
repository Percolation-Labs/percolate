/* Supported renderers consume data, never generated scripts or HTML. */
export const rendererNames={table:'Table',cards:'Cards',plot:'Plot',graph:'Graph'};
export function rendererError(type,options,columns,rows){
 const has=c=>typeof c==='string'&&columns.includes(c);
 const numeric=c=>has(c)&&rows.every(r=>r[c]==null||typeof r[c]==='number'&&Number.isFinite(r[c]));
 const scalar=c=>has(c)&&rows.every(r=>r[c]==null||['string','number','boolean'].includes(typeof r[c]));
 if(type==='table')return '';
 if(type==='cards'){
  if(!scalar(options.card_title))return 'Choose a title field containing text or a number.';
  if(!Array.isArray(options.card_fields)||options.card_fields.length>6||!options.card_fields.every(has))return 'Choose up to six card detail fields.';
  return '';
 }
 if(type==='plot'){
  if(!has(options.x)||!numeric(options.y)||options.x===options.y)return 'Choose distinct X and numeric Y fields.';
  if(!['bar','line','scatter'].includes(options.form))return 'Choose a chart type.';
  if(options.form==='scatter'&&!numeric(options.x))return 'Scatter requires numeric X and Y fields.';
  return '';
 }
 if(type==='graph'){
  if(!has(options.source)||!has(options.target)||options.source===options.target)return 'Choose distinct source and target fields representing actual relationships.';
  if(rows.some(r=>![r[options.source],r[options.target]].every(v=>['string','number'].includes(typeof v)&&v!==null)))return 'Graph endpoints must be non-empty text or numbers.';
  if(options.relation&&!has(options.relation))return 'Choose a valid relationship label field.';
  return '';
 }
 return 'Unknown renderer.';
}
