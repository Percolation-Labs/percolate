"""Call the core workspace canvas as a scoped caller, from chat or voice tooling.

python dev/canvas_call.py open
python dev/canvas_call.py query '{"query":"workflow_steps"}'
python dev/canvas_call.py view '{"control":"plot","options":{"x":"step","y":"tasks"}}'
python dev/canvas_call.py consume

Credentials: P8_CANVAS_REST and P8_CANVAS_TOKEN, or local-only .local/canvas-client.json.
This client never connects to the proprietary application.
"""
import json
import os
import sys
from pathlib import Path
from urllib.request import Request, urlopen


def call(action, body):
    local = Path('.local/canvas-client.json')
    cfg = json.loads(local.read_text()) if local.exists() else {}
    rest = os.environ.get('P8_CANVAS_REST', cfg.get('rest', ''))
    token = os.environ.get('P8_CANVAS_TOKEN', cfg.get('token', ''))
    if not rest or not token:
        raise SystemExit('Set P8_CANVAS_REST and P8_CANVAS_TOKEN to your workspace endpoint and scoped token.')
    request = Request(rest.rstrip('/')+'/rpc/canvas', data=json.dumps({'p_action':action,'p_body':body}).encode(), headers={
        'Authorization':'Bearer '+token, 'Content-Type':'application/json', 'Content-Profile':'workflow'})
    with urlopen(request, timeout=10) as response:
        return json.load(response)

if __name__ == '__main__':
    print(json.dumps(call(sys.argv[1], json.loads(sys.argv[2]) if len(sys.argv)>2 else {}), indent=2))
