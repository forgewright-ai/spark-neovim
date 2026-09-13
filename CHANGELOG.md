# Changelog

## 1.0.1

- The `spark: thinking` notice names the size -- `spark: thinking --
  6142 characters` -- the same fact the reader plugins' pulse shows;
  the editor stays non-blocking, so the line is still, not animated.

## 1.0.0

- spark in neovim, spark-micro's whole shape under one key: the `spark> `
  prompt (complete at the cursor, rewrite the selection or the file, `?`
  asks in a pane, `??` goes on in its thread, `ledger [clear]`), the pane
  keys (q, Enter to a quote, a applies code, d declines to the ledger),
  and the splice safety -- an answer whose text moved meanwhile opens in
  a pane instead of being spliced over the wrong place.
- Everything is one call to `spark edit` with the text on stdin: the
  filetype, the basename and the about-hint travel as hints, the path
  never does; the plugin speaks no HTTP and sees no token.
- The pty test (`tests/neovim_pty.py`) drives a real neovim against a
  stub spark, spark-micro's cases ported whole; CI runs it on Ubuntu,
  Arch and macOS.
