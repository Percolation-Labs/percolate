"""Explicit renderer requests normalize onto the durable canvas view contract."""
RENDERER_SCHEMA = {
    'type': 'object', 'required': ['type'], 'additionalProperties': False,
    'properties': {
        'type': {'type': 'string', 'enum': ['table', 'cards', 'plot', 'graph']},
        **{name: {'type': 'string'} for name in ('x', 'y', 'source', 'target', 'relation', 'title')},
        'form': {'type': 'string', 'enum': ['bar', 'line', 'scatter']},
        'fields': {'type': 'array', 'items': {'type': 'string'}, 'maxItems': 6},
    },
    'description': 'Declare the view. Plot requires x, y, form; graph requires source, target; cards require title and fields. Table is the default. Mappings must name actual result columns.',
}

def normalize_renderer(args):
    if 'renderer' not in args:
        return args
    if args.get('action') not in ('query', 'view'):
        raise ValueError('Use renderer only with query or view.')
    if 'control' in args or 'options' in args:
        raise ValueError('Use renderer or control/options, not both.')
    value = args['renderer']
    if not isinstance(value, dict) or value.get('type') not in ('table', 'cards', 'plot', 'graph'):
        raise ValueError('Choose a table, cards, plot or graph renderer.')
    kind = value['type']
    allowed = {'table': set(), 'cards': {'title', 'fields'}, 'plot': {'x', 'y', 'form'}, 'graph': {'source', 'target', 'relation'}}[kind]
    if set(value) - allowed - {'type'}:
        raise ValueError('Renderer contains fields that do not apply to this view.')
    required = allowed - {'relation'}
    if not required <= value.keys():
        raise ValueError(f'{kind} requires explicit {", ".join(sorted(required))}.')
    options = {}
    for key in allowed & value.keys():
        item = value[key]
        if key == 'fields':
            if not isinstance(item, list) or len(item) > 6 or not all(isinstance(c, str) and c for c in item):
                raise ValueError('Cards need up to six named detail fields.')
        elif not isinstance(item, str) or not item:
            raise ValueError(f'Renderer {key} must name a field or chart type.')
        options[{'title': 'card_title', 'fields': 'card_fields'}.get(key, key)] = item
    if kind == 'plot' and options['form'] not in ('bar', 'line', 'scatter'):
        raise ValueError('Choose bar, line or scatter.')
    return {**{k: v for k, v in args.items() if k != 'renderer'}, 'control': kind, 'options': options}

def describe_renderer(doc):
    view = doc.get('view') if isinstance(doc, dict) else None
    if view:
        kind, opts = view.get('control', 'table'), view.get('options') or {}
        keys = {'table': [], 'plot': ['x', 'y', 'form'], 'graph': ['source', 'target', 'relation'], 'cards': ['card_title', 'card_fields']}.get(kind, [])
        view['renderer'] = {'type': kind, **{{'card_title': 'title', 'card_fields': 'fields'}.get(k, k): opts[k] for k in keys if opts.get(k) is not None}}
    return doc
