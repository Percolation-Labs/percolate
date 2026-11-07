"""Opt-in shared workspace tool; SQL owns identity, state and authorization."""
import json
from .canvas_app import URI
from .renderers import RENDERER_SCHEMA, normalize_renderer, describe_renderer

TOOL = {
    'name': 'canvas',
    '_meta': {'ui': {'resourceUri': URI}},
    'description': 'Query actual Percolate tables with statement (one read-only SQL query, caller permissions), or choose workflow_runs (counts by status)/workflow_steps (task counts by step and status). Results are saved on the core canvas. Declare renderer: table (default); plot with x/y/form; graph with source/target and optional relation; cards with a meaningful title field and up to six fields. Never infer relationships or card layouts from column order. Use action=view to change a renderer without querying again. Legacy control/options remains supported but cards require card_title/card_fields. Selected rows and graph nodes return with the next tool call. Limit results to 500 rows/48KB; graph views to 150 nodes/300 edges. Open a session first: open creates one if absent, otherwise explicitly reports session_action=resumed and retains its view. Close then open for a fresh session. A query applies its supplied control/options atomically and clears the previous result selection. In MCP Apps hosts this tool opens an interactive canvas inside the chat; use this tool rather than generating an HTML artifact or a localhost link.',
    'inputSchema': {'type':'object','required':['action'],'properties': {
        'action': {'type':'string','enum':['open','read','query','view','consume','close']},
        'query': {'type':'string','enum':['workflow_runs','workflow_steps']},
        'control': {'type':'string','enum':['table','cards','plot','graph']},
        'statement': {'type':'string','maxLength':12000,'description':'One read-only SQL query against tables/views this caller can read.'},
        'session': {'type':'string'}, 'result_set': {'type':'string'},
        'renderer': RENDERER_SCHEMA,
        'caption': {'type':'string'}, 'options': {'type':'object'}}}}

def call(upstream, args, authorization):
    if not isinstance(args, dict) or args.get('action') not in TOOL['inputSchema']['properties']['action']['enum']:
        return {'isError':True,'content':[{'type':'text','text':'Choose a canvas action.'}]}
    try:
        args=normalize_renderer(args)
    except ValueError as error:
        return {'isError':True,'content':[{'type':'text','text':str(error)}]}
    body={k:v for k,v in args.items() if k!='action'}
    action=args['action']
    if action=='query' and not body.get('caption'):
        body['caption']='Query result' if 'statement' in body else {'workflow_runs':'Run counts by status','workflow_steps':'Task counts by step and status'}.get(body.get('query'),'Query result')
    if action=='query' and 'statement' in args:
        statement=args['statement']
        if not isinstance(statement,str) or not statement.strip() or len(statement)>12000:
            return {'isError':True,'content':[{'type':'text','text':'Supply one SQL query of at most 12000 characters.'}]}
        # Separate RPC, under the caller's identity. Never run SQL in the canvas
        # definer function: that would turn a display into a privileged reader.
        rows, error=upstream.rpc('sql_passthrough',{'p_statement':statement},authorization,'aiq')
        if error:
            return {'isError':True,'content':[{'type':'text','text':json.dumps(error)}]}
        if not isinstance(rows,list) or any(not isinstance(row,dict) for row in rows):
            return {'isError':True,'content':[{'type':'text','text':'This query did not return table rows.'}]}
        columns=list(dict.fromkeys(key for row in rows for key in row))
        if len(rows)>500 or len(columns)>50:
            return {'isError':True,'content':[{'type':'text','text':'Canvas supports at most 500 rows and 50 columns; narrow the query.'}]}
        action='present';body.update(rows=rows,columns=columns)
    doc, error = upstream.rpc('canvas', {'p_action':action,'p_body':body}, authorization, 'workflow')
    if error:
        return {'isError':True,'content':[{'type':'text','text':json.dumps(error)}]}
    if args['action'] not in ('consume','close'):
        touches, err = upstream.rpc('canvas',{'p_action':'consume','p_body':{}},authorization,'workflow')
        if not err and touches: doc['since_last_call']=touches.get('since_last_call',[])
    doc=describe_renderer(doc)
    # The browser reads the full saved result; a conversational reply previews it.
    if doc.get('view'):
        result=doc['view']['result'];result['row_count']=len(result['rows']);result['rows']=result['rows'][:5]
    return {'content':[{'type':'text','text':json.dumps(doc)}],'structuredContent':doc}
