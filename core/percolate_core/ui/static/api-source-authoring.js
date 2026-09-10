export const API_DEFAULTS={name:'',description:'',url:'',params:{},headers:{},auth_type:'none',credential_ref:'',auth_header:'X-API-Key',
  records_path:'$',id_path:'id',watermark_type:'timestamp',watermark_field:'updated_at',watermark_param:'since',initial_watermark:'',overlap_seconds:60,
  pagination:'link_header',next_path:'next',page_param:'page',page_size_param:'per_page',page_size:100,max_pages:5,mappings:{}};
export const GITHUB_EXAMPLE={...API_DEFAULTS,name:'github-issues',description:'Keep a current, deduplicated issue feed for a repeatable triage workflow.',
  url:'https://api.github.com/repos/pallets/markupsafe/issues',params:{state:'all',sort:'updated',direction:'asc'},
  headers:{Accept:'application/vnd.github+json'},page_size:100,max_pages:3,
  mappings:{issue_id:'id',number:'number',title:'title',status:'state',author:'user.login',updated_at:'updated_at',url:'html_url'}};
// Public contract: TheSpaceDevs/spaceflightnewsapi src/api/views/filters.py.
export const NEWS_EXAMPLE={...API_DEFAULTS,name:'spaceflight-news',description:'Keep a current news feed for a recurring briefing workflow.',
  url:'https://api.spaceflightnewsapi.net/v4/articles/',params:{ordering:'updated_at'},records_path:'results',
  watermark_param:'updated_at_gte',pagination:'next_url',next_path:'next',page_size_param:'limit',page_size:20,max_pages:2,
  mappings:{article_id:'id',title:'title',publisher:'news_site',url:'url',published_at:'published_at',updated_at:'updated_at'}};
export function recentNewsExample(){return {...NEWS_EXAMPLE,initial_watermark:new Date(Date.now()-7*86400000).toISOString()};}
export function apiSourcePackage(id,settings,queue='ingest'){
  if(!settings||typeof settings!=='object'||Array.isArray(settings))throw Error('API settings must be an object.');
  const unknown=Object.keys(settings).filter(k=>!Object.hasOwn(API_DEFAULTS,k));
  if(unknown.length)throw Error('Unknown API settings: '+unknown.join(', '));
  const s={...API_DEFAULTS,...settings};
  for(const [key,value] of Object.entries(API_DEFAULTS))if(typeof value==='string'&&typeof s[key]!=='string')throw Error(key+' must be text.');
  if(!/^[a-z][a-z0-9_-]{0,63}$/.test(s.name))throw Error('Give the source a lowercase name, starting with a letter (up to 64 letters, numbers, hyphens or underscores).');
  if(!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id))throw Error('Create a new source to get a valid identity.');
  let url;try{url=new URL(s.url);}catch(_){throw Error('Enter a complete HTTP or HTTPS endpoint.');}
  if(!['http:','https:'].includes(url.protocol)||url.username||url.password||url.hash)throw Error('The endpoint cannot contain embedded credentials or a fragment.');
  for(const key of ['params','headers','mappings'])if(!s[key]||typeof s[key]!=='object'||Array.isArray(s[key]))throw Error(key+' must be a JSON object.');
  if([...Object.keys(s.params),...url.searchParams.keys()].some(k=>/^(access_token|api_key|token|password)$/i.test(k))||Object.keys(s.headers).some(k=>/^(authorization|cookie|x-api-key|api-key)$/i.test(k)))throw Error('Use a credential reference for authentication. Remove literal tokens and authentication headers.');
  if(!['none','bearer','header'].includes(s.auth_type))throw Error('Choose no authentication, bearer token or API key header.');
  if(s.auth_type!=='none'&&!/^[A-Z][A-Z0-9_]*$/.test(s.credential_ref))throw Error('Name the worker credential, for example GITHUB_TOKEN. Do not paste its value.');
  if(!['none','timestamp','number'].includes(s.watermark_type))throw Error('Choose a timestamp, numeric or no watermark.');
  if(s.watermark_type!=='none'&&(!s.watermark_field||!s.watermark_param))throw Error('Choose the record watermark field and the request parameter that filters updates.');
  if(s.initial_watermark&&s.watermark_type==='timestamp'&&(!/(Z|[+-]\d\d:\d\d)$/.test(s.initial_watermark)||!Number.isFinite(Date.parse(s.initial_watermark))))throw Error('Include a timezone in the initial timestamp, such as 2026-01-01T00:00:00Z.');
  if(s.initial_watermark&&s.watermark_type==='number'&&!Number.isFinite(Number(s.initial_watermark)))throw Error('The initial numeric watermark must be a number.');
  if(!s.id_path.trim())throw Error('Choose a stable record ID field for deduplication.');
  if(!['none','link_header','next_url','page_token','page'].includes(s.pagination))throw Error('Choose a supported pagination method.');
  if(['next_url','page_token'].includes(s.pagination)&&!s.next_path.trim())throw Error('Enter the field containing the next URL or page token.');
  for(const [k,min,max] of [['page_size',1,1000],['max_pages',1,100],['overlap_seconds',0,604800]])if(!Number.isInteger(s[k])||s[k]<min||s[k]>max)throw Error(k+' must be a whole number from '+min+' to '+max+'.');
  if(Object.values(s.params).some(v=>!['string','number','boolean'].includes(typeof v)||typeof v==='number'&&!Number.isInteger(v)))throw Error('Query parameter values must be text, whole numbers or booleans.');
  if(Object.values(s.headers).some(v=>typeof v!=='string')||Object.entries(s.headers).some(([k,v])=>/[\r\n:]/.test(k)||/[\r\n]/.test(v)))throw Error('Headers must have valid names and text values without line breaks.');
  for(const [name,rule] of Object.entries(s.mappings)){
    if(!name||!(typeof rule==='string'&&rule.trim()||rule&&typeof rule==='object'&&!Array.isArray(rule)&&typeof rule.path==='string'&&rule.path.trim()&&Object.keys(rule).every(k=>['path','cast'].includes(k))&&(!rule.cast||['string','number','boolean','lowercase','trim'].includes(rule.cast))))throw Error('Mapping '+name+' needs a field path and an optional supported cast.');
  }
  if(s.auth_type==='header'&&(!s.auth_header||/[\r\n:]/.test(s.auth_header)))throw Error('Choose a valid authentication header name.');
  if(!queue.trim())throw Error('Choose an ingestion worker queue.');
  const {name,description,...api}=s;
  const workflow={name:'source_'+id.replaceAll('-',''),steps:[{id:'pull',work:true,queue,input:{op:'api_pull',source_name:name}}]};
  const source={name,kind:'http_pull',config:{description,api,editor:{version:1,kind:'api',queue},ingest_workflow:workflow.name,workflow}};
  return {name:name.replace(/[_-]+/g,'-').replace(/-$/,''),version:'0.1.0',description,requires:'percolate >= 0.2.0',sources:[source],workflows:[{name:workflow.name,yaml:JSON.stringify(workflow,null,2)}]};
}
export function apiPackageText(m){return '# Percolate incremental API source package. Save as manifest.yaml.\n# Includes configuration and workflow; excludes records, watermarks, checkpoints and credential values.\n# Install with an explicit owner: packages/apply.py PACKAGE --owner USER_UUID.\n# Destination needs the API ingestion worker, its queue and declared credential references.\n'+JSON.stringify(m,null,2)+'\n';}
