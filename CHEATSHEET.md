# neovim with spark -- the cheatsheet

neovim edits; spark writes with you. Section 1 is survival neovim,
section 2 is the one key that puts your own AI inside it.

The key spellings here are the editor's: `Alt-s` (the suggested bind)
is Option-s on a Mac -- spark's Terminal profile makes Option the
Meta key -- or Esc and then s, quickly. `Ctrl-r` means hold Ctrl and
press r. Keys are case-sensitive.

## 1. neovim, the basics

Modes

    i              insert text at the cursor
    Esc            back to normal mode (where keys are commands)
    v              select by character; V by line

Files

    :w Enter       save         :q Enter    quit
    :wq Enter      save + quit  :q! Enter   quit, drop changes

Editing (normal mode)

    u              undo         Ctrl-r   redo
    yy             copy line    dd       cut line
    p              paste below the cursor
    y and d        copy / cut the selection

Moving and finding

    gg / G         top / bottom of the file
    :42 Enter      go to line 42
    /words Enter   search -- then n next match, N previous
    :help spark    the plugin's full help (once: :helptags ALL)

## 2. the text, with spark

One key (your bind; Alt-s suggested). The `spark> ` prompt opens;
what you type there decides what happens. A rewrite comes back
selected -- a proposal, never applied silently. Answers open in a
pane on the right; the pane is read-only and single keys act there.

    (nothing) Enter  complete at the cursor -- end your text with a
                     space or a new line first
    words            rewrite the selection (or the whole file):
                     select the whole unit you mean, not a word of it
    ? words          ask about the selection, in a pane
    ?                review: quoted notes, each checked against your
                     text -- an invented one says [not in the text]
    ?? words         go on in the newest pane's thread
    ledger [clear]   the notes you declined for this file
    u                undo any applied rewrite

In a spark pane

    q or Esc         close the pane
    Enter            jump to this note's quote in your file
    a                apply the code block under the cursor
    d                decline this note: the next review of this file
                     is told not to raise it again

By example

    fix grammar               rewrite the selection, grammar only
    shorter                   the same text, tighter
    translate to Portuguese   the selection, in Portuguese
    ? is the title too long   a question, answered in a pane
    ?                         review before you call it done

Tell spark what the text is when it should not guess:
`vim.b.spark_about = "a novel chapter"` (or `vim.g.spark_about` for
everywhere). `:help spark` says the rest.
