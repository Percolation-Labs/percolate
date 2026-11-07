#!/usr/bin/env python3
"""Write a launchd job for an already-provisioned, restricted SSH relay account.

This does not install server SSH keys, change DNS, or load the job. Review the
printed plist path, then use launchctl bootstrap as described in README.md.
"""
import argparse
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', required=True)
parser.add_argument('--key', type=Path, required=True)
parser.add_argument('--remote-bind', required=True, help='Private cluster bridge address.')
parser.add_argument('--remote-port', type=int, default=18142)
parser.add_argument('--local-port', type=int, default=8142)
parser.add_argument('--user', default='percolate-relay')
parser.add_argument('--label', default='dev.percolate.local-connector-tunnel')
parser.add_argument('--log-directory', type=Path, required=True)
parser.add_argument('--replace', action='store_true')
args = parser.parse_args()
if any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-' for c in args.label):
    parser.error('label must contain only letters, digits, dots and hyphens')
if not args.key.is_file() or args.key.stat().st_mode & 0o077:
    parser.error('key must exist and have owner-only permissions')
if not all(1 <= port <= 65535 for port in (args.local_port, args.remote_port)):
    parser.error('ports must be between 1 and 65535')
args.log_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
job = Path.home() / 'Library/LaunchAgents' / (args.label + '.plist')
job.parent.mkdir(parents=True, exist_ok=True)
command = ['/usr/bin/ssh', '-F', '/dev/null', '-N', '-T', '-i', str(args.key.resolve()),
           '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
           '-o', 'StrictHostKeyChecking=yes', '-o', 'ExitOnForwardFailure=yes',
           '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
           '-o', 'ConnectTimeout=10', '-R',
           f'{args.remote_bind}:{args.remote_port}:127.0.0.1:{args.local_port}',
           f'{args.user}@{args.host}']
config = {'Label': args.label, 'ProgramArguments': command, 'RunAtLoad': True,
          'KeepAlive': True, 'ThrottleInterval': 10,
          'StandardOutPath': str(args.log_directory.resolve() / 'relay.log'),
          'StandardErrorPath': str(args.log_directory.resolve() / 'relay.log')}
with job.open('wb' if args.replace else 'xb') as out:
    job.chmod(0o600)
    plistlib.dump(config, out)
print(job)
