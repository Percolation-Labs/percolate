"""MCP App resource and host-mediated UI operations. No browser credentials."""
import json
import hashlib
from .renderers import describe_renderer
from pathlib import Path

APP_PATH = Path(__file__).parents[1] / 'ui/static/canvas-app.html'
URI = 'ui://percolate/canvas-' + hashlib.sha256(APP_PATH.read_bytes()).hexdigest()[:16] + '.html'
MIME = 'text/html;profile=mcp-app'
RESOURCE = {'uri': URI, 'name': 'Percolate Canvas', 'mimeType': MIME}
TOOL = {
    'name': 'canvas_ui',
    'description': 'Read the full canvas or save a view/selection from its embedded UI.',
    '_meta': {'ui': {'resourceUri': URI, 'visibility': ['app']}},
    'inputSchema': {'type': 'object', 'required': ['action'], 'properties': {
        'action': {'type': 'string', 'enum': ['read', 'view', 'touch']},
        'session': {'type': 'string'}, 'known_session': {'type': 'string'},
        'after': {'type': 'integer'}, 'result_set': {'type': 'string'},
        'control': {'type': 'string', 'enum': ['table', 'cards', 'plot', 'graph']},
        'options': {'type': 'object'}, 'kind': {'type': 'string', 'enum': ['selection']},
        'rows': {'type': 'array', 'items': {'type': 'integer'}},
        'columns': {'type': 'array', 'items': {'type': 'string'}},
        'nodes': {'type': 'array', 'items': {'type': 'string'}}}}
}

def resource():
    return {'contents': [{**RESOURCE,
        'text': APP_PATH.read_text(),
        '_meta': {'ui': {'csp': {'connectDomains': [], 'resourceDomains': []}}}}]}

def call(upstream, args, authorization):
    if not isinstance(args, dict) or args.get('action') not in ('read', 'view', 'touch'):
        return {'isError': True, 'content': [{'type': 'text', 'text': 'Choose read, view or touch.'}]}
    body = {k: v for k, v in args.items() if k != 'action'}
    if args['action'] == 'touch' and body.get('kind') != 'selection':
        return {'isError': True, 'content': [{'type': 'text', 'text': 'Only selection touches are supported.'}]}
    doc, error = upstream.rpc('canvas', {'p_action': args['action'], 'p_body': body}, authorization, 'workflow')
    if error:
        return {'isError': True, 'content': [{'type': 'text', 'text': json.dumps(error)}]}
    # UI reads must not consume the touch cursor: the next model call owns it.
    return {'content': [], 'structuredContent': describe_renderer(doc)}
