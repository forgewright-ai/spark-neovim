local VERSION = "1.0.1"

-- spark/init.lua -- spark in neovim (the second smart tool). One key opens
-- the `spark> ` prompt; Enter alone completes at the cursor, words rewrite
-- the selection (or the whole file when nothing is selected), `? words`
-- asks in a pane on the right, `?` alone reviews, `?? words` goes on in the
-- newest pane's thread. Every run is one call to `spark edit` (contract 10)
-- with the text on stdin: the plugin never speaks HTTP, never sees a token,
-- never sends the file's path -- spark owns all of that. Solicited only:
-- nothing runs until you ask.
--
-- In a spark pane, single keys act (the pane is not modifiable): q and
-- Escape close it, Enter jumps to the quote on the line, a applies the
-- code block under the cursor, d declines the note under the cursor
-- (spark edit --decline: not raised again for this file).
--
-- The plugin binds NO key itself: the key is one line the user adds to
-- their init.lua (README):
--     vim.keymap.set({ "n", "x" }, "<M-s>", function() require("spark").prompt() end)
-- Switch it off with `vim.g.spark_disable = true`.
--
-- The Lua here stays in the 5.1/5.4 common subset (neovim runs LuaJIT;
-- the pre-commit hook's luac may be 5.4): no goto, no integer division.

local M = { VERSION = VERSION }

local api = vim.api

local pending = false      -- one run at a time
local current = nil        -- the state of the run in flight

-- The panes: pane bufnr -> {origin_buf, origin_win, file, sel, thread};
-- `newest` is the one `??` goes on in.
local panes = {}
local newest = nil

-- ------------------------------------------------------------- helpers --
local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function basename(p)
    return (p:gsub("^.*/", ""))
end

local function readable(p)
    local f = io.open(p, "r")
    if f == nil then return false end
    f:close()
    return true
end

-- The binary: SPARK_BIN (tests), g:spark_bin, ~/.local/bin/spark (a GUI
-- session may never have sourced the rc files that put it on PATH), then
-- whatever PATH answers to.
local function bin()
    local env = os.getenv("SPARK_BIN")
    if env ~= nil and env ~= "" then return env end
    local opt = vim.g.spark_bin
    if opt ~= nil and opt ~= "" then return opt end
    local home = os.getenv("HOME") or ""
    if home ~= "" and readable(home .. "/.local/bin/spark") then
        return home .. "/.local/bin/spark"
    end
    return "spark"
end

-- neovim counts bytes everywhere the plugin looks (cursor columns, marks,
-- nvim_buf_get_offset): micro's rune arithmetic collapses to this pattern,
-- kept only to step over one UTF-8 character.
local UTF8 = "[%z\1-\127\194-\244][\128-\191]*"

local function charlen(line, col)
    local ch = line:sub(col + 1):match(UTF8)
    return ch and #ch or 0
end

local function notice(msg)
    api.nvim_echo({ { msg } }, false, {})
end

local function moan(msg)
    api.nvim_echo({ { msg, "ErrorMsg" } }, true, {})
end

-- The buffer as the bytes spark gets on stdin; the same construction feeds
-- the --at/--sel offset math, so an offset always indexes these bytes.
local function buffer_text(buf)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
    local text = table.concat(lines, "\n")
    if vim.bo[buf].eol then text = text .. "\n" end
    return text
end

local function offset_at(buf, row, col)
    return api.nvim_buf_get_offset(buf, row) + col
end

-- Where the write position lands after `chunk` goes in at {row, col}.
local function advance(loc, chunk)
    local pieces = vim.split(chunk, "\n", { plain = true })
    if #pieces > 1 then
        return { loc[1] + #pieces - 1, #pieces[#pieces] }
    end
    return { loc[1], loc[2] + #chunk }
end

local function insert_at(buf, loc, chunk)
    local was = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_text(buf, loc[1], loc[2], loc[1], loc[2],
                          vim.split(chunk, "\n", { plain = true }))
    vim.bo[buf].modifiable = was
end

-- ---------------------------------------------------------- selections --
-- sel: {kind = "char"|"line", s_row, s_col, e_row, e_col, text} -- rows
-- 0-based, byte columns, end exclusive; "line" spans whole rows and its
-- text carries the trailing newline (so select-all matches micro's bytes).
local function selection(buf)
    local mode = vim.fn.mode()
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then return nil end
    local p1, p2 = vim.fn.getpos("v"), vim.fn.getpos(".")
    local sr, sc, er, ec = p1[2], p1[3], p2[2], p2[3]
    if er < sr or (er == sr and ec < sc) then
        sr, sc, er, ec = er, ec, sr, sc
    end
    if mode == "V" then
        local lines = api.nvim_buf_get_lines(buf, sr - 1, er, true)
        return { kind = "line", s_row = sr - 1, e_row = er - 1,
                 text = table.concat(lines, "\n") .. "\n" }
    end
    local last = api.nvim_buf_get_lines(buf, er - 1, er, true)[1]
    local e_col = math.min(ec - 1 + charlen(last, ec - 1), #last)
    local ok, chunk = pcall(api.nvim_buf_get_text, buf, sr - 1, sc - 1, er - 1, e_col, {})
    if not ok then return nil end
    return { kind = "char", s_row = sr - 1, s_col = sc - 1, e_row = er - 1,
             e_col = e_col, text = table.concat(chunk, "\n") }
end

-- What the buffer holds now where sel was, or nil when the range is gone.
local function text_of(buf, sel)
    if sel.kind == "line" then
        if sel.e_row >= api.nvim_buf_line_count(buf) then return nil end
        local lines = api.nvim_buf_get_lines(buf, sel.s_row, sel.e_row + 1, false)
        if #lines == 0 then return nil end
        return table.concat(lines, "\n") .. "\n"
    end
    local ok, chunk = pcall(api.nvim_buf_get_text, buf, sel.s_row, sel.s_col,
                            sel.e_row, sel.e_col, {})
    if not ok then return nil end
    return table.concat(chunk, "\n")
end

local function sel_offsets(buf, sel)
    if sel.kind == "line" then
        return offset_at(buf, sel.s_row, 0), api.nvim_buf_get_offset(buf, sel.e_row + 1)
    end
    return offset_at(buf, sel.s_row, sel.s_col), offset_at(buf, sel.e_row, sel.e_col)
end

local function select_range(win, buf, s_row, s_col, e_row, e_col)
    -- visual mode lives in the current window: focus it, then select;
    -- end col points at the last character of the range, inclusive
    if not api.nvim_win_is_valid(win) then return end
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { s_row + 1, s_col })
    vim.cmd("normal! v")
    api.nvim_win_set_cursor(win, { e_row + 1, math.max(e_col - 1, 0) })
end

-- The splice, and the selection left on it (a proposal, never silent).
local function splice(win, buf, sel, acc)
    if sel.kind == "line" then
        local body = (acc:gsub("\n$", ""))
        local lines = vim.split(body, "\n", { plain = true })
        api.nvim_buf_set_lines(buf, sel.s_row, sel.e_row + 1, true, lines)
        local last = lines[#lines]
        select_range(win, buf, sel.s_row, 0, sel.s_row + #lines - 1, #last)
        return
    end
    api.nvim_buf_set_text(buf, sel.s_row, sel.s_col, sel.e_row, sel.e_col,
                          vim.split(acc, "\n", { plain = true }))
    local to = advance({ sel.s_row, sel.s_col }, acc)
    select_range(win, buf, sel.s_row, sel.s_col, to[1], to[2])
end

local function argv(buf, extra)
    local args = { "edit", "--type", vim.bo[buf].filetype }
    local path = api.nvim_buf_get_name(buf)
    if path ~= "" then
        args[#args + 1] = "--name"
        args[#args + 1] = basename(path)
    end
    local about = vim.b[buf].spark_about or vim.g.spark_about
    if about ~= nil and about ~= "" then
        args[#args + 1] = "--about"
        args[#args + 1] = about
    end
    for _, w in ipairs(extra) do args[#args + 1] = w end
    return args
end

local function words_of(s)
    local t = {}
    for w in s:gmatch("%S+") do t[#t + 1] = w end
    return t
end

-- ---------------------------------------------------------------- pane --
local function forget_pane(pbuf)
    panes[pbuf] = nil
    if newest == pbuf then newest = nil end
end

local ASK_KEYS = "spark: q closes; Enter jumps to a quote, a applies code, d declines a note, ?? goes on"

local function pane_keys(pbuf)
    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = pbuf, nowait = true, silent = true })
    end
    map("q", function() M._close(pbuf) end)
    map("<Esc>", function() M._close(pbuf) end)
    map("<CR>", function() M._jump(pbuf) end)
    map("a", function() M._apply(pbuf) end)
    map("d", function() M._decline(pbuf) end)
end

-- A new pane on the right; `sel` is the selection the pane's question was
-- about (nil for the whole file).
local function open_pane(bp, sel)
    local pbuf = api.nvim_create_buf(false, true)
    vim.bo[pbuf].bufhidden = "wipe"
    vim.bo[pbuf].filetype = "markdown"
    vim.cmd("botright vsplit")
    local pwin = api.nvim_get_current_win()
    api.nvim_win_set_buf(pwin, pbuf)
    -- a narrow pane of prose: wrap on screen, between words
    vim.wo[pwin].wrap = true
    vim.wo[pwin].linebreak = true
    vim.wo[pwin].number = false
    local path = api.nvim_buf_get_name(bp.buf)
    local entry = { origin_buf = bp.buf, origin_win = bp.win,
                    file = path ~= "" and basename(path) or "",
                    sel = sel,
                    thread = string.format("edit-%d-%04d", os.time(), math.random(0, 9999)) }
    panes[pbuf] = entry
    newest = pbuf
    pane_keys(pbuf)
    api.nvim_create_autocmd("BufWipeout", {
        buffer = pbuf,
        callback = function() forget_pane(pbuf) end,
    })
    return pbuf, entry
end

-- An answer that cannot be spliced is still an answer: a pane holds it.
local function show_pane(bp, text)
    local pbuf = open_pane(bp, nil)
    insert_at(pbuf, { 0, 0 }, text)
    vim.bo[pbuf].modifiable = false
end

local function origin_of(entry)
    if not api.nvim_buf_is_valid(entry.origin_buf) then return nil end
    local win = entry.origin_win
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= entry.origin_buf then
        win = nil
        for _, w in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_get_buf(w) == entry.origin_buf then win = w end
        end
        if win == nil then return nil end
        entry.origin_win = win
    end
    return { buf = entry.origin_buf, win = win }
end

-- ---------------------------------------------------------------- jobs --
-- state: {kind, bp, buf, loc, start, sel, acc, err, got, ...}
local function on_out(state, chunk)
    if chunk == "" then return end
    state.got = true
    if state.kind == "rewrite" or state.kind == "decline" or state.kind == "notice" then
        state.acc = state.acc .. chunk      -- spliced, or shown, only once whole
        return
    end
    insert_at(state.buf, state.loc, chunk)
    state.loc = advance(state.loc, chunk)
end

local function on_exit(state)
    pending = false
    current = nil
    if state.kind == "notice" then
        local why = trim(state.err ~= "" and state.err or state.acc)
        notice("spark: " .. (why ~= "" and why or "done"))
        return
    end
    if state.kind == "decline" then
        -- silence and exit 0 is success; a refusal comes on stdout, a die on stderr
        local why = trim(state.err ~= "" and state.err or state.acc)
        if why ~= "" then
            moan(why)
            return
        end
        local was = vim.bo[state.buf].modifiable
        vim.bo[state.buf].modifiable = true
        api.nvim_buf_set_lines(state.buf, state.from, state.to, true, {})
        vim.bo[state.buf].modifiable = was
        notice("spark: declined -- not raised again for " .. state.file)
        return
    end
    if not state.got then
        local why = trim(state.err)
        if why == "" then why = "spark: nothing came back" end
        moan(why)
        return
    end
    if state.kind == "rewrite" then
        if state.acc == state.sel.text then
            notice("spark: unchanged")
            return
        end
        -- the text it rewrote must still be there: an edit meanwhile moved
        -- or shrank it, and a splice over a stale range corrupts the file
        if text_of(state.buf, state.sel) ~= state.sel.text then
            show_pane(state.bp, state.acc)
            notice("spark: the text changed while it thought -- the answer is in the pane, q closes")
            return
        end
        if state.whole then
            local body = (state.acc:gsub("\n$", ""))
            api.nvim_buf_set_lines(state.buf, 0, -1, true, vim.split(body, "\n", { plain = true }))
            pcall(api.nvim_win_set_cursor, state.bp.win, { 1, 0 })
            notice("spark: the file is rewritten -- u undoes")
        else
            splice(state.bp.win, state.buf, state.sel, state.acc)
            notice("spark: rewritten -- u undoes")
        end
    elseif state.kind == "ask" then
        vim.bo[state.buf].modifiable = false
        if state.anchor then
            for _, w in ipairs(api.nvim_list_wins()) do
                if api.nvim_win_get_buf(w) == state.buf then
                    pcall(api.nvim_win_set_cursor, w, { state.anchor[1] + 1, state.anchor[2] })
                end
            end
        end
        notice(ASK_KEYS)
    else
        select_range(state.bp.win, state.buf, state.start[1], state.start[2],
                     state.loc[1], state.loc[2])
        notice("spark: done -- u undoes")
    end
end

-- A Lua error inside a job callback must not take the editor down: each
-- handler runs scheduled and protected, and an error becomes one line.
local function guarded(fn)
    return function(...)
        local args = { ... }
        vim.schedule(function()
            local fine, err = pcall(fn, unpack(args))
            if not fine then
                pending = false
                current = nil
                moan("spark: " .. tostring(err))
            end
        end)
    end
end

local function spawn(bp, args, stdin, state)
    state.err, state.got = "", false
    state.acc = state.acc or ""
    pending = true
    current = state
    local cmd = { bin() }
    for _, a in ipairs(args) do cmd[#cmd + 1] = a end
    local ok, job = pcall(vim.fn.jobstart, cmd, {
        -- each callback's list joined with newlines is the raw byte
        -- stream: neovim splits on them and hands partials at the edges
        on_stdout = guarded(function(_, data)
            on_out(state, table.concat(data, "\n"))
        end),
        on_stderr = guarded(function(_, data)
            state.err = state.err .. table.concat(data, "\n")
        end),
        on_exit = guarded(function()
            on_exit(state)
        end),
    })
    if not ok or job <= 0 then
        pending = false
        current = nil
        moan("spark: could not start " .. bin())
        return
    end
    state.job = job
    vim.fn.chansend(job, stdin)
    vim.fn.chanclose(job, "stdin")
    notice(("spark: thinking -- %d characters"):format(#stdin))
end

-- --------------------------------------------------------------- kinds --
local function complete(bp)
    local pos = api.nvim_win_get_cursor(bp.win)
    local row, col = pos[1] - 1, pos[2]
    -- normal mode puts the cursor ON a character; the continuation goes
    -- after it (end your text with a space and it begins exactly there)
    local line = api.nvim_buf_get_lines(bp.buf, row, row + 1, true)[1]
    if #line > 0 then col = math.min(col + charlen(line, col), #line) end
    local at = offset_at(bp.buf, row, col)
    local state = { kind = "complete", bp = bp, buf = bp.buf,
                    loc = { row, col }, start = { row, col } }
    spawn(bp, argv(bp.buf, { "--at", tostring(at) }), buffer_text(bp.buf), state)
end

-- The selection is what gets rewritten; nothing selected means the whole
-- file, replaced in place (the brief asks for the whole rewritten text, so
-- inserting it at the cursor would double the file). A selection travels
-- with --part: a fragment must come back as exactly that fragment.
local function rewrite(bp, words, sel)
    local text, extra
    if sel then
        text = sel.text
        extra = { "--part" }
        for _, w in ipairs(words) do extra[#extra + 1] = w end
    else
        text = buffer_text(bp.buf)
        sel = { kind = "line", s_row = 0, e_row = api.nvim_buf_line_count(bp.buf) - 1,
                text = text }
        extra = words
    end
    local state = { kind = "rewrite", bp = bp, buf = bp.buf, acc = "",
                    sel = sel, whole = extra[1] ~= "--part" }
    spawn(bp, argv(bp.buf, extra), text, state)
end

-- A question: the WHOLE buffer goes on stdin; a selection travels as
-- --sel A B (byte offsets), so spark sees the file around it. `follow`
-- (?? words) goes on in the newest pane's thread: the same --thread id,
-- the answer under the question at the pane's end.
local function ask(bp, words, follow, sel)
    local text = buffer_text(bp.buf)
    if trim(text) == "" then
        notice("spark: nothing to ask about")
        return
    end
    local extra = {}
    if sel then
        local a, b = sel_offsets(bp.buf, sel)
        extra = { "--sel", tostring(a), tostring(b) }
    end
    for _, w in ipairs(words) do extra[#extra + 1] = w end
    local pbuf, entry, state
    if follow and newest and panes[newest] then
        pbuf, entry = newest, panes[newest]
        local last = api.nvim_buf_line_count(pbuf) - 1
        local lastline = api.nvim_buf_get_lines(pbuf, last, last + 1, true)[1]
        local at = { last, #lastline }
        local asked = {}
        for i = 2, #words do asked[#asked + 1] = words[i] end
        local q = "\n\n> " .. (#asked > 0 and table.concat(asked, " ") or "?") .. "\n\n"
        insert_at(pbuf, at, q)
        if sel then entry.sel = sel end
        local loc = advance(at, q)
        state = { kind = "ask", bp = bp, buf = pbuf, loc = loc, anchor = { loc[1], loc[2] } }
    else
        pbuf, entry = open_pane(bp, sel)
        state = { kind = "ask", bp = bp, buf = pbuf, loc = { 0, 0 } }
    end
    extra[#extra + 1] = "--thread"
    extra[#extra + 1] = entry.thread
    spawn(bp, argv(bp.buf, extra), text, state)
end

-- The ledger: what was declined for this file, in a pane; `clear` drops
-- it. Both are spark edit --ledger [clear] --name FILE, nothing on stdin.
local function ledger_pane(bp, clear)
    if api.nvim_buf_get_name(bp.buf) == "" then
        notice("spark: an unnamed buffer keeps no ledger -- save it first")
        return
    end
    if clear then
        spawn(bp, argv(bp.buf, { "--ledger", "clear" }), "",
              { kind = "notice", bp = bp, acc = "", err = "" })
        return
    end
    local pbuf = open_pane(bp, nil)
    spawn(bp, argv(bp.buf, { "--ledger" }), "",
          { kind = "ask", bp = bp, buf = pbuf, loc = { 0, 0 } })
end

-- ------------------------------------------------------ the pane's keys --
-- The first quoted span on a line: "..." or the curly pair or `...`.
local function first_quote(line)
    local best, span = nil, nil
    for _, pat in ipairs({ '"([^"]+)"', "\226\128\156([^\226]+)\226\128\157", "`([^`]+)`" }) do
        local s, _, m = line:find(pat)
        if s and (best == nil or s < best) then best, span = s, m end
    end
    return span
end

-- A vim pattern that matches `s` literally, any run of whitespace in it
-- matching any run (the quote may cross a line break in the file).
local function loose_pattern(s)
    local esc = vim.fn.escape(s, "\\")
    return "\\V" .. (esc:gsub("%s+", "\\_s\\+"))
end

function M._close(pbuf)
    if pending and current and current.buf == pbuf then
        notice("spark: still writing here -- a moment")
        return
    end
    -- bufhidden=wipe: closing the window wipes the buffer and its entry
    for _, w in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(w) == pbuf then
            api.nvim_win_close(w, true)
            return
        end
    end
end

-- Enter: the origin's cursor goes to the quote on this line, selected.
function M._jump(pbuf)
    local entry = panes[pbuf]
    if entry == nil then return end
    local row = api.nvim_win_get_cursor(0)[1] - 1
    local span = first_quote(api.nvim_buf_get_lines(pbuf, row, row + 1, true)[1])
    if span == nil then
        notice("spark: no quote on this line")
        return
    end
    local origin = origin_of(entry)
    if origin == nil then
        notice("spark: the file's window is closed")
        return
    end
    local pat = loose_pattern(span)
    local pwin = api.nvim_get_current_win()
    api.nvim_set_current_win(origin.win)
    api.nvim_win_set_cursor(origin.win, { 1, 0 })
    local s = vim.fn.searchpos(pat, "cW")
    local e = s[1] ~= 0 and vim.fn.searchpos(pat, "ceW") or { 0, 0 }
    if s[1] == 0 or e[1] == 0 then
        api.nvim_set_current_win(pwin)
        notice("spark: not in the text as written")
        return
    end
    api.nvim_win_set_cursor(origin.win, { s[1], s[2] - 1 })
    vim.cmd("normal! v")
    api.nvim_win_set_cursor(origin.win, { e[1], e[2] - 1 })
end

-- The code block under the cursor: the lines indented four spaces around
-- it (the brief's shape), dedented; else the fenced block the cursor is
-- in. nil when there is none.
local function code_block(pbuf, y)
    local lines = api.nvim_buf_get_lines(pbuf, 0, -1, true)
    local n = #lines
    local function indented(i) return lines[i + 1]:match("^    ") ~= nil end
    local function blankl(i) return trim(lines[i + 1]) == "" end
    if indented(y) then
        local top, bot = y, y
        while top > 0 and (indented(top - 1) or (blankl(top - 1) and top > 1 and indented(top - 2))) do top = top - 1 end
        while bot < n - 1 and (indented(bot + 1) or (blankl(bot + 1) and bot + 2 < n and indented(bot + 2))) do bot = bot + 1 end
        local out = {}
        for i = top, bot do out[#out + 1] = (lines[i + 1]:gsub("^    ", "")) end
        return table.concat(out, "\n") .. "\n"
    end
    local function fence(i) return lines[i + 1]:match("^%s*```") ~= nil end
    local top = y
    while top >= 0 and not fence(top) do top = top - 1 end
    if top < 0 then return nil end
    local bot = y + 1
    while bot < n and not fence(bot) do bot = bot + 1 end
    if bot >= n or bot <= top + 1 then return nil end
    local out = {}
    for i = top + 1, bot - 1 do out[#out + 1] = lines[i + 1] end
    return table.concat(out, "\n") .. "\n"
end

-- a: the code block under the cursor replaces the selection the question
-- was about when it is still there, else lands at the origin's cursor.
function M._apply(pbuf)
    local entry = panes[pbuf]
    if entry == nil then return end
    local y = api.nvim_win_get_cursor(0)[1] - 1
    local text = code_block(pbuf, y)
    if text == nil then
        notice("spark: no code here -- a block is indented four spaces, or fenced")
        return
    end
    local origin = origin_of(entry)
    if origin == nil then
        notice("spark: the file's window is closed")
        return
    end
    local sel
    if entry.sel ~= nil and text_of(origin.buf, entry.sel) == entry.sel.text then
        sel = entry.sel
    else
        local pos = api.nvim_win_get_cursor(origin.win)
        sel = { kind = "char", s_row = pos[1] - 1, s_col = pos[2],
                e_row = pos[1] - 1, e_col = pos[2], text = "" }
    end
    local at, to
    if sel.kind == "line" then
        local body = (text:gsub("\n$", ""))
        local block = vim.split(body, "\n", { plain = true })
        api.nvim_buf_set_lines(origin.buf, sel.s_row, sel.e_row + 1, true, block)
        at = { sel.s_row, 0 }
        to = { sel.s_row + #block - 1, #block[#block] }
    else
        api.nvim_buf_set_text(origin.buf, sel.s_row, sel.s_col, sel.e_row, sel.e_col,
                              vim.split(text, "\n", { plain = true }))
        at = { sel.s_row, sel.s_col }
        to = advance(at, text)
    end
    entry.sel = { kind = "char", s_row = at[1], s_col = at[2],
                  e_row = to[1], e_col = to[2], text = text }
    select_range(origin.win, origin.buf, at[1], at[2], to[1], to[2])
    api.nvim_set_current_win(origin.win)
    notice("spark: applied -- u undoes")
end

-- d: the note under the cursor (the numbered paragraph, or the paragraph)
-- goes to the ledger; it leaves the pane when spark has kept it.
function M._decline(pbuf)
    local entry = panes[pbuf]
    if entry == nil then return end
    if entry.file == "" then
        notice("spark: an unnamed buffer keeps no ledger -- save it first")
        return
    end
    if pending then
        notice("spark: still working -- one at a time")
        return
    end
    local lines = api.nvim_buf_get_lines(pbuf, 0, -1, true)
    local n = #lines
    local y = api.nvim_win_get_cursor(0)[1] - 1
    local function numbered(i) return lines[i + 1]:match("^%d+[%.%)]%s") ~= nil end
    local function blankl(i) return trim(lines[i + 1]) == "" end
    if blankl(y) then
        notice("spark: no note here")
        return
    end
    local top = y
    while top > 0 and not numbered(top) and not blankl(top - 1) do top = top - 1 end
    local bot = y
    while bot + 1 < n and not blankl(bot + 1) and not numbered(bot + 1) do bot = bot + 1 end
    local note = {}
    for i = top, bot do note[#note + 1] = lines[i + 1] end
    local state = { kind = "decline", bp = { buf = pbuf }, buf = pbuf,
                    from = top, to = bot + 1, file = entry.file, acc = "" }
    spawn(state.bp, { "edit", "--decline", "--name", entry.file },
          table.concat(note, "\n") .. "\n", state)
end

-- ------------------------------------------------------------- the key --
local function run(bp, line, sel)
    line = trim(line or "")
    if pending then
        notice("spark: still working -- one at a time")
        return
    end
    -- from inside a spark pane, the file it belongs to is meant
    local entry = panes[bp.buf]
    if entry ~= nil then
        local origin = origin_of(entry)
        if origin == nil then
            notice("spark: the file's window is closed")
            return
        end
        bp, sel = origin, nil
    end
    if not vim.bo[bp.buf].modifiable or vim.bo[bp.buf].readonly then
        moan("spark: this buffer is read-only")
        return
    end
    if line == "" then
        complete(bp)
    elseif line:sub(1, 2) == "??" then
        local words = words_of(line:sub(3))
        table.insert(words, 1, "?")
        ask(bp, words, true, sel)
    elseif line:sub(1, 1) == "?" then
        local words = words_of(line:sub(2))
        table.insert(words, 1, "?")
        ask(bp, words, false, sel)
    elseif line == "ledger" or line == "ledger clear" then
        ledger_pane(bp, line == "ledger clear")
    elseif line == "lua" then
        -- the one word that is not an instruction: the shell has it
        notice("spark lua -- this one runs in the dark; ask your shell")
    else
        rewrite(bp, words_of(line), sel)
    end
end

function M.prompt()
    if vim.g.spark_disable then return end
    if pending then
        notice("spark: still working -- one at a time")
        return
    end
    local bp = { buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win() }
    local sel = selection(bp.buf)
    if sel ~= nil then
        api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    end
    local fine, resp = pcall(vim.fn.input, { prompt = "spark> ", cancelreturn = "\1" })
    notice("")
    if not fine or resp == "\1" then return end
    run(bp, resp, sel)
end

function M.command(opts)
    if vim.g.spark_disable then return end
    local bp = { buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win() }
    local sel = nil
    if opts.range and opts.range > 0 then
        local sr = opts.line1 - 1
        local er = opts.line2 - 1
        local lines = api.nvim_buf_get_lines(bp.buf, sr, er + 1, true)
        sel = { kind = "line", s_row = sr, e_row = er,
                text = table.concat(lines, "\n") .. "\n" }
    end
    run(bp, opts.args, sel)
end

return M
