# spark-neovim -- spark inside neovim

spark (https://spark.forgewright.ai) is your own AI on your own machine;
this plugin puts it under one key in neovim. The key opens the `spark> `
prompt; what you type there decides what happens:

    (nothing) Enter    complete at the cursor
    words              rewrite the selection, or the whole file
    ? words            ask about it, in a pane on the right
    ?                  review: notes, each quote checked against your text
    ?? words           go on in the newest pane's thread
    ledger [clear]     the notes you declined for this file

The new text is left selected: a proposal, never applied silently.
`:help spark` inside neovim says the rest (run `:helptags ALL` once).

## Install

You need spark 1.7 or newer on this machine (`spark edit -h` answers), and
neovim 0.9 or newer. Then:

```sh
git clone https://github.com/forgewright-ai/spark-neovim ~/.config/nvim/pack/spark/start/spark
```

and one line in your `init.lua`:

```lua
vim.keymap.set({ "n", "x" }, "<M-s>", function() require("spark").prompt() end)
```

The plugin binds no key by itself; Alt-s is the suggestion (Option-s on a
Mac -- spark's Terminal profile makes Option the Meta key), any key works.
Update with `git -C ~/.config/nvim/pack/spark/start/spark pull`. A plugin
manager does the same from the repo's address (lazy.nvim:
`{ "forgewright-ai/spark-neovim" }`).

## Options

- `vim.g.spark_about` -- a sticky hint: what this buffer is, when spark
  should not guess ("a poem", "a changelog"); `vim.b.spark_about` narrows
  it to one buffer.
- `vim.g.spark_bin` -- the spark binary, when it is not on PATH.
- `vim.g.spark_disable = true` -- switch the plugin off.

## What leaves this machine

The file's name and its text -- 6 kB around the cursor for a completion,
12 kB for a rewrite, 16 kB for a question -- never its path, and only to
the brain spark is configured for. Every run is one call to `spark edit`
with the text on stdin; the plugin never speaks HTTP and never sees a
token. spark's README says the rest.

## Contributing

`git config core.hooksPath .githooks` once; the hook keeps the tree free of
private names, ASCII, and syntax-clean. `python3 tests/neovim_pty.py` drives
a real neovim in a pty against a stub spark (skips without neovim). Another
editor joins spark the same way this one does: one client of `spark edit`,
in its own repo.

MIT. Credits in `CREDITS.md`. Built with Claude.
