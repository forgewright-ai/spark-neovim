#!/usr/bin/env python3
# neovim_pty.py -- the spark plugin inside a real neovim, in a pty, against
# a stub `spark` (SPARK_BIN) that logs what it was asked and answers a
# fixed word. Proves the whole loop the editor depends on: Alt-s opens the
# prompt, words reach `spark edit` with the filetype, the name and the
# about-hint (never the path), the answer lands in the buffer, `?` opens a
# pane, :Spark works without Alt. Skips (exit 0) where neovim is not
# installed. The cases are spark-micro's (tests/micro_pty.py), ported.
#
#   python3 tests/neovim_pty.py

import fcntl
import os
import re
import pty
import select
import shutil
import struct
import sys
import tempfile
import termios
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = REPO                                   # the repo root is the plugin
CSI = re.compile(r"\x1b(?:\[[0-9;?]*[ -/]*[@-~]|\([A-Za-z0-9]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])")

STUB = r'''#!/bin/sh
# the stub spark: log argv and stdin, answer one word
printf '%s\n' "$*" >> "$STUB_LOG"
cat > "$STUB_LOG.stdin"
case " $* " in
    *" --decline "*) exit 0 ;;
    *" --ledger clear "*) printf 'dropped 2 notes for note.md\n'; exit 0 ;;
    *" --ledger "*) printf 'note.md: 2 notes, newest first\nSTUB-LEDGER\n'; exit 0 ;;
    *" ? "*)      printf '1. "hello" is plain -- say more\n2. "nothing here" drifts\n\n    print("fixed")\n\nASKED-%s\nSTUB-ASK\n' "$(printf '%s' "$*" | sed 's/.* ? //; s/ --thread.*//; s/ /-/g')"; exit 0 ;;
    *" --at "*)   printf 'STUB-DONE'; exit 0 ;;
    *" keep it "*) cat "$STUB_LOG.stdin"; exit 0 ;;
    *" fail "*)   printf 'spark: no brain today -- spark serve\n' >&2; exit 1 ;;
    *" slow "*)   sleep 2; printf 'STUB-SLOW'; exit 0 ;;
esac
printf 'STUB-EDIT'
'''

# the README's one line, plus the harness: the repo on the runtimepath and
# the sticky about-hint for markdown (micro's settings.json equivalent)
INIT = '''vim.opt.runtimepath:prepend(%r)
vim.opt.swapfile = false
vim.opt.writebackup = false
vim.cmd("runtime! plugin/spark.lua")
vim.keymap.set({ "n", "x" }, "<M-s>", function() require("spark").prompt() end)
vim.api.nvim_create_autocmd("FileType", {
    pattern = "markdown",
    callback = function() vim.b.spark_about = "a note" end,
})
'''


class Editor:
    def __init__(self, argv, env, cwd, rows=30, cols=100):
        self.buf = b""
        self.pos = 0
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def read(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if r:
                try:
                    data = os.read(self.fd, 4096)
                except OSError:
                    return
                if not data:
                    return
                self.buf += data

    def plain(self):
        """what was drawn since mark(), with the escape sequences removed"""
        return CSI.sub("", self.buf[self.pos:].decode("utf-8", "replace"))

    def expect(self, text, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if text in self.plain():
                return True
            self.read(0.2)
        return False

    def send(self, s):
        os.write(self.fd, s.encode())
        time.sleep(0.2)

    def mark(self):
        self.pos = len(self.buf)

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def main():
    nvim = shutil.which("nvim")
    if not nvim:
        print("neovim_pty: neovim is not installed here -- skipped (apt-get install neovim / brew install neovim)")
        return 0
    fail = 0

    def ok(cond, what, extra=""):
        nonlocal fail
        print("  %s %s%s" % ("ok  " if cond else "FAIL", what, ("   " + extra) if extra and not cond else ""))
        if not cond:
            fail += 1

    with tempfile.TemporaryDirectory(prefix="spark-neovim-") as tmp:
        work, bindir = [os.path.join(tmp, d) for d in ("work", "bin")]
        os.makedirs(work)
        os.makedirs(bindir)
        init = os.path.join(tmp, "init.lua")
        with open(init, "w") as f:
            f.write(INIT % PLUGIN)
        stub = os.path.join(bindir, "spark")
        with open(stub, "w") as f:
            f.write(STUB)
        os.chmod(stub, 0o755)
        log = os.path.join(tmp, "stub.log")
        note = os.path.join(work, "note.md")
        with open(note, "w") as f:
            f.write("hello world\n")
        env = {"HOME": tmp, "TERM": "xterm-256color", "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "SPARK_BIN": stub, "STUB_LOG": log}
        argv = [nvim, "-u", init, "-i", "NONE", "note.md"]

        def logged():
            try:
                with open(log) as f:
                    return f.read()
            except OSError:
                return ""

        def fresh(text="hello world\n"):
            if os.path.exists(log):
                os.unlink(log)
            with open(note, "w") as f:
                f.write(text)
            m = Editor(argv, env, work)
            ok(m.expect(text.splitlines()[0]), "neovim draws the file")
            m.mark()
            return m

        # A. Alt-s, words: a rewrite with nothing selected rewrites the whole file
        m = fresh()
        m.send("\x1bs")
        ok(m.expect("spark>"), "Alt-s opens the spark> prompt", m.plain()[-300:])
        m.send("make it shine\r")
        ok(m.expect("rewritten"), "the whole file is rewritten in place", m.plain()[-300:])
        m.send(":w\r")
        time.sleep(0.5)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(note) as f:
            saved = f.read()
        ok(saved in ("STUB-EDIT", "STUB-EDIT\n"), "the saved file is the answer, nothing doubled", repr(saved))
        got = logged()
        ok("edit --type markdown --name note.md --about a note make it shine" in got and "--part" not in got,
           "spark edit got the filetype, the name, the about-hint and the words, no --part", got)
        ok(work not in got, "the file's path never reaches spark", got)
        try:
            with open(log + ".stdin") as f:
                stdin = f.read()
        except OSError:
            stdin = ""
        ok(stdin == "hello world\n", "the whole buffer travelled on stdin", repr(stdin))

        # A2. a summary-shaped rewrite is shown, not spliced: words
        # without a ? that come back a fraction of a big text land in
        # the pane, and the file keeps its text
        big = os.path.join(work, "big.md")
        with open(big, "w") as f:
            f.write(("the fair runs on saturdays in the central square " * 16).strip() + "\n")
        m = Editor([nvim, "-u", init, "-i", "NONE", "big.md"], env, work)
        ok(m.expect("central"), "the big file draws", m.plain()[-200:])
        m.send("\x1bs")
        m.expect("spark>")
        m.send("summarize this text\r")
        ok(m.expect("spliced"), "a far-shorter rewrite is shown, not spliced", m.plain()[-300:])
        m.send("q")                  # close the pane
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(big) as f:
            kept = f.read()
        ok("central square" in kept and "STUB-EDIT" not in kept,
           "the file keeps its text: nothing was destroyed", repr(kept[:80]))

        # B. :Spark (no Alt), a question: a pane on the right
        m = fresh()
        m.send(":Spark ? why\r")
        ok(m.expect("STUB-ASK"), "`:Spark ? why` answers in a pane", m.plain()[-300:])
        got = logged()
        ok("--name note.md --about a note ? why" in got, "the question reaches spark edit as ? words", got)
        m.send("q")
        time.sleep(0.4)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(note) as f:
            ok(f.read() == "hello world\n", "a question changes nothing in the file")

        # C. Alt-s, Enter: a completion at the cursor (after the character
        # under it: $ puts the cursor on the last byte of `hello world`)
        m = fresh()
        m.send("$")
        m.send("\x1bs")
        ok(m.expect("spark>"), "Alt-s again")
        m.send("\r")
        ok(m.expect("STUB-DONE"), "Enter alone completes at the cursor", m.plain()[-300:])
        got = logged()
        ok("--at 11" in got, "the completion names the byte offset", got)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # D. a real selection (ggVG selects all): the rewrite replaces it
        m = fresh()
        m.send("ggVG")
        m.send("\x1bs")
        ok(m.expect("spark>"), "Alt-s over a selection")
        m.send("shorter\r")
        ok(m.expect("rewritten"), "the selection is replaced and the message says so", m.plain()[-300:])
        m.send(":w\r")
        time.sleep(0.5)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(note) as f:
            saved = f.read()
        ok(saved in ("STUB-EDIT", "STUB-EDIT\n"), "the whole selection became the answer, nothing else", repr(saved))
        with open(log + ".stdin") as f:
            ok(f.read() == "hello world\n", "the selection travelled on stdin")
        ok("--part shorter" in logged(), "a selection travels with --part", logged())

        # E. an unchanged rewrite splices nothing
        m = fresh()
        m.send("ggVG")
        m.send("\x1bs")
        m.expect("spark>")
        m.send("keep it\r")
        ok(m.expect("unchanged"), "a reply equal to the selection says unchanged", m.plain()[-300:])
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(note) as f:
            ok(f.read() == "hello world\n", "the file is untouched")

        # F. spark's stderr is shown verbatim
        m = fresh()
        m.send("\x1bs")
        m.expect("spark>")
        m.send("fail\r")
        ok(m.expect("no brain today"), "spark's die hint is shown", m.plain()[-300:])
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # G. the file is edited while spark thinks: nothing is spliced over
        # the stale range; the answer opens in a pane; neovim lives on
        m = fresh("hello world\nsecond line\n")
        m.send("\x1bs")
        m.expect("spark>")
        m.send("slow\r")
        time.sleep(0.5)
        m.send("ggdG")              # the buffer is emptied meanwhile
        ok(m.expect("thought", 6), "a whole-file answer over a changed buffer is refused", m.plain()[-300:])
        ok(m.expect("STUB-SLOW", 2), "the answer is shown in a pane instead")
        ok(os.waitpid(m.pid, os.WNOHANG) == (0, 0), "neovim is still running")
        m.send("q")                 # the pane
        time.sleep(0.4)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(note) as f:
            ok(f.read() == "hello world\nsecond line\n", "the file on disk is untouched")

        # H. the same over a selection that moved
        m = fresh("hello world\nsecond line\n")
        m.send("ggVG")
        m.send("\x1bs")
        m.expect("spark>")
        m.send("slow\r")
        time.sleep(0.5)
        m.send("ggix\x1b")          # a letter typed at the top meanwhile
        ok(m.expect("thought", 6), "a selection answer over a changed buffer is refused", m.plain()[-300:])
        ok(os.waitpid(m.pid, os.WNOHANG) == (0, 0), "neovim is still running")
        m.send("q")
        time.sleep(0.4)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # I. q closes the pane (then :qa! ends neovim)
        def ask_pane(text="hello world\n"):
            mm = fresh(text)
            mm.send("\x1bs")
            mm.expect("spark>")
            mm.send("? why\r")
            ok(mm.expect("STUB-ASK"), "the pane answers", mm.plain()[-300:])
            return mm

        def gone(mm, what):
            end = time.time() + 6
            left = False
            while time.time() < end and not left:
                mm.read(0.3)
                left = os.waitpid(mm.pid, os.WNOHANG) != (0, 0)
            ok(left, what, mm.plain()[-300:])
            mm.close()

        m = ask_pane()
        m.send("q")
        time.sleep(0.5)
        m.read(0.3)
        m.send(":qa!\r")
        gone(m, "q closes the pane: :qa! ends neovim")

        # J. Escape closes the pane
        m = ask_pane()
        m.send("\x1b")
        time.sleep(0.6)
        m.read(0.3)
        m.send(":qa!\r")
        gone(m, "Escape closes the pane: :qa! ends neovim")

        # K. Enter on a note jumps to its quote in the file, selected; c then
        # replaces the selection
        m = ask_pane()
        m.send("gg")
        m.send("\r")
        time.sleep(0.4)
        m.send("cX\x1b")
        time.sleep(0.3)
        m.send(":w\r")
        time.sleep(0.5)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(note) as f:
            saved = f.read()
        ok(saved == "X world\n", "Enter jumps to the quote: X replaced the selected hello", repr(saved))

        # L. a applies the code block under the cursor at the file's cursor
        m = ask_pane()
        m.send("gg3j")              # to the indented line
        m.send("a")
        ok(m.expect("applied", 3), "a says applied", m.plain()[-400:])
        m.send(":w\r")
        time.sleep(0.5)
        m.send(":qa!\r")
        m.read(1.0)
        m.close()
        with open(note) as f:
            saved = f.read()
        ok(saved == 'print("fixed")\nhello world\n', "a spliced the dedented block at the cursor", repr(saved))

        # M. d declines the note under the cursor: spark edit --decline gets
        # the note on stdin under the file's name; the note leaves the pane
        m = ask_pane()
        m.send("gg")
        m.mark()
        m.send("d")
        ok(m.expect("declined"), "d declines the note (the message says so)", m.plain()[-300:])
        got = logged()
        ok("edit --decline --name note.md" in got, "the decline names the file, never its path", got)
        with open(log + ".stdin") as f:
            ok(f.read() == '1. "hello" is plain -- say more\n', "the note travelled on stdin")
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # N. ?? goes on in the pane's thread: the same --thread id, the
        # question and a second answer under the first
        m = ask_pane()
        m.send("\x1bs")             # from inside the pane: the file is meant
        m.expect("spark>")
        m.send("?? furthermore\r")
        ok(m.expect("ASKED-furthermore"), "?? answers in the same pane", m.plain()[-300:])
        ids = re.findall(r"--thread (edit-\d+-\d+)", logged())
        ok(len(ids) == 2 and ids[0] == ids[1], "? and ?? name one thread id", str(ids))
        ok("furthermore" in m.plain().split("ASKED-furthermore")[0], "the pane shows the follow-up question above its answer", m.plain()[-300:])
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # O. a selection question sends the whole buffer with --sel
        m = fresh()
        m.send("ggVG")
        m.send("\x1bs")
        m.expect("spark>")
        m.send("? why\r")
        ok(m.expect("STUB-ASK"), "a selection question answers")
        got = logged()
        ok("--sel 0 12" in got and "--part" not in got, "a selection travels as --sel A B, never --part", got)
        with open(log + ".stdin") as f:
            ok(f.read() == "hello world\n", "the whole buffer travelled on stdin with --sel")
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # P. two panes at once hold two answers
        m = ask_pane()
        m.send("\x1bs")
        m.expect("spark>")
        m.send("? again\r")
        ok(m.expect("ASKED-again"), "a second ? opens a second pane", m.plain()[-300:])
        m.mark()
        m.send("q")                  # the second pane goes
        time.sleep(0.6)
        m.read(0.5)
        shown = m.plain()
        ok("ASKED-why" in shown and "ASKED-again" not in shown, "the first pane kept its own answer", shown[-400:])
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # Q. one word at the prompt is not an instruction: the message says
        # where it lives, nothing runs (no spark call is logged)
        m = fresh()
        m.send("\x1bs")
        m.expect("spark>")
        m.send("lua\r")
        ok(m.expect("dark"), "the word lua at the prompt points to the shell", m.plain()[-300:])
        time.sleep(0.4)
        ok(not os.path.exists(log), "and runs nothing")
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

        # R. ledger at the prompt opens the file's declined notes in a pane;
        # ledger clear drops them and says so
        m = fresh()
        m.send("\x1bs")
        m.expect("spark>")
        m.send("ledger\r")
        ok(m.expect("STUB-LEDGER"), "ledger at the prompt: the notes in a pane", m.plain()[-300:])
        got = logged()
        ok("edit --type" in got and "--name note.md" in got and got.rstrip().endswith("--ledger"),
           "the pane asked spark edit --ledger with the file's name, never its path", got)
        m.send("q")                  # the pane goes
        time.sleep(0.5)
        m.mark()
        m.send("\x1bs")
        m.expect("spark>")
        m.send("ledger clear\r")
        ok(m.expect("dropped"), "ledger clear: spark's line is shown", m.plain()[-300:])
        m.send(":qa!\r")
        m.read(1.0)
        m.close()

    print("neovim_pty: %s" % ("all ok" if not fail else "%d FAILED" % fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
