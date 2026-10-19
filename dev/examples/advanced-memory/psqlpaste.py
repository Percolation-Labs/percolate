#!/usr/bin/env python3
"""Paste SQL blocks into one interactive psql, the way a reader's terminal does.

    psqlpaste.py <dsn> <cmd-fifo> <ack-fifo>

The reader opens one psql session and pastes each block whole. A psql built
with readline turns on bracketed paste, so a pasted block arrives as one
edit: a `\\gset` that is not the last line of its block swallows the rest, and
a block that relies on a variable or a pg_temp function from an earlier block
needs the same session. Feeding statements one at a time with -f hides both.

For each line "<block> <capture>" read from the command fifo, this pastes the
block inside the terminal's bracketed-paste markers, presses Enter, waits for
the prompt to come back, writes everything the terminal showed to the capture
file, and answers "ok" or "error" on the ack fifo.
"""
import os, pty, re, select, sys, time

dsn, cmd_fifo, ack_fifo = sys.argv[1:4]
PROMPT = re.compile(rb"\n[\w-]+=[#>] $")
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[=>]|\r")

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["PAGER"] = "cat"
    os.execvp("psql", ["psql", dsn])


def read_until_prompt(timeout=900):
    buf, quiet_since, deadline = b"", None, time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            buf += chunk
            quiet_since = None
        else:
            clean = ANSI.sub(b"", buf)
            if PROMPT.search(clean[-200:] if len(clean) > 200 else b"\n" + clean):
                quiet_since = quiet_since or time.time()
                if time.time() - quiet_since > 0.6:
                    return buf
    return buf


read_until_prompt(60)
with open(cmd_fifo) as cmds, open(ack_fifo, "w") as acks:
    for line in cmds:
        block, capture = line.split()
        text = open(block).read().rstrip("\n")
        os.write(fd, b"\x1b[200~" + text.encode() + b"\x1b[201~\r")
        shown = ANSI.sub(b"", read_until_prompt()).decode(errors="replace")
        with open(capture, "w") as out:
            out.write(shown)
        bad = "ERROR:" in shown or "extra argument" in shown  # the second is a \gset that swallowed its block
        acks.write(("error" if bad else "ok") + "\n")
        acks.flush()
os.write(fd, b"\\q\r")
