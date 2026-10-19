#!/usr/bin/env python3
"""Every tutorial block survives a reader's paste.

A tutorial's psql blocks are pasted, not typed. psql with readline 8 turns
bracketed paste on (Homebrew's psql, and Debian's, which is the image's), so a
pasted block arrives as ONE line, and a backslash command that is not the
block's last line takes everything after it as its arguments:

    \\gset: extra argument ":'a'" ignored

Nothing after it runs and nothing reports a failure. The Mem0 reader found it
on 20 Oct 2026, and five LangGraph tour blocks had it. A harness that feeds
psql through a pipe, line by line, cannot see it, so this pastes each block,
bracketed, into an interactive psql in a pseudo-terminal, the way a reader's
terminal does, and reads what psql says.

    dev/pastecheck.py --container p8-ci [file ...]

With no files it checks every test file under dev/tests that marks its blocks
`-- block: <name>` ... `-- /block`. It pastes into the container's `postgres`
database, so nothing lands in the database under test: the errors it looks for
are psql's own, raised before any statement is sent.
"""
import argparse, os, pathlib, pty, re, select, signal, sys, time

HERE = pathlib.Path(__file__).resolve().parent
BLOCK = re.compile(r"^-- block: (\S+)\n(.*?)\n-- /block", re.S | re.M)
# What psql says when a paste mangled a block. Measured, not guessed: each is
# what psql 18/19 prints for a backslash command that swallowed what followed it.
MANGLED = re.compile(r"extra argument .* ignored|invalid command|unterminated quoted")


def paste(argv, block):
    """Paste one block into an interactive psql started by argv; return all it printed."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", PAGER="cat")
        os.execvp(argv[0], argv)

    def drain(until, seconds):
        out, end = b"", time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    break
                if until and until in out:
                    break
        return out.decode(errors="replace")

    drain(b"=#", 15)
    os.write(fd, b"\x1b[200~" + block.encode() + b"\x1b[201~\r")
    os.write(fd, b"\\echo __PASTED__\r")
    out = drain(b"__PASTED__\r\n", 60)
    os.write(fd, b"\\q\r")
    drain(None, 1)
    # A psql that did not reach the marker (a block left open, a pager waiting
    # for a key) does not quit on \q either, so it is ended rather than waited on.
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--container", default=os.environ.get("CONTAINER", "p8-ci"))
    ap.add_argument("files", nargs="*")
    a = ap.parse_args()
    files = a.files or sorted(str(p) for p in (HERE / "tests").rglob("*.sql") if BLOCK.search(p.read_text()))
    # PAGER is the container's, not ours: without it psql pages a long result and waits for a key.
    argv = ["docker", "exec", "-it", "-e", "PAGER=cat", a.container, "psql", "-U", "p8", "-d", "postgres"]
    blocks, broken = 0, []
    for f in files:
        for name, body in BLOCK.findall(pathlib.Path(f).read_text()):
            blocks += 1
            out = paste(argv, body)
            hit = MANGLED.search(out)
            if hit:
                broken.append(f"{os.path.relpath(f)}: block {name}: psql said {hit.group(0)!r}")
            elif "__PASTED__\r\n" not in out:
                broken.append(f"{os.path.relpath(f)}: block {name}: psql never came back to its prompt after the paste")
    for b in broken:
        print("FAILED: " + b)
    if broken:
        print("A pasted block arrives as one line, so a backslash command that is not its block's last line "
              "swallows the rest. Look the value up inline instead of with \\gset.")
        return 1
    print(f"{blocks} blocks in {len(files)} file(s) paste intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
