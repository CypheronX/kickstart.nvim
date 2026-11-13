-- Ask Claude quick questions without leaving Neovim (normal or visual mode):
--   `<leader>?`  how to do something in Neovim (sends mode, filetype and this config's keymaps)
--   `<leader>c`  C# / .NET syntax or API (sends the code around the cursor, or the visual selection)
--
-- Opens a prompt in the middle of the screen; the answer appears in a floating window.
-- Uses `claude -p` (Haiku for Neovim, Sonnet for C#) with no tools, no project settings
-- (so it is quick and never touches files).
-- In the answer window: `<CR>`/`q`/`<Esc>` close, `a` asks a follow-up.

local M = {}

local function user_keymaps()
  local lines = {}
  for _, mode in ipairs { 'n', 'x', 'i' } do
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if map.desc and map.desc ~= '' then
        table.insert(lines, string.format('%s %s  %s', mode, (map.lhs:gsub(' ', '<Space>')), map.desc))
      end
    end
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
      if map.desc and map.desc ~= '' then
        table.insert(lines, string.format('%s %s  %s (buffer)', mode, (map.lhs:gsub(' ', '<Space>')), map.desc))
      end
    end
  end
  return table.concat(lines, '\n')
end

-- The visual selection, or ~40 lines around the cursor with the cursor line marked.
local function code_context(mode)
  local file = vim.fn.expand '%:.'
  if mode:match '^[vV\22]' then
    local region = vim.fn.getregion(vim.fn.getpos 'v', vim.fn.getpos '.', { type = mode })
    return string.format('File: %s\nSelected code (the question is about this):\n```\n%s\n```', file, table.concat(region, '\n'))
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local first = math.max(row - 20, 1)
  local lines = vim.api.nvim_buf_get_lines(0, first - 1, row + 20, false)
  for i, line in ipairs(lines) do
    if first + i - 1 == row then lines[i] = line .. '    // <-- cursor' end
  end
  return string.format('File: %s\nCode around the cursor (may or may not be relevant):\n```\n%s\n```', file, table.concat(lines, '\n'))
end

local TOPICS = {
  nvim = {
    title = 'Ask about Neovim',
    model = 'haiku', -- fast; keymap answers are simple
    width = 80,
    system_prompt = [[
You answer questions about Neovim keyboard shortcuts and commands for someone still learning Vim.
Rules:
- Start with the exact keys or command on the first line, in a code span, e.g. `ci"`.
- Then explain in 1-3 short plain sentences what each key means (the "grammar": operator + motion/text object),
  so it is easy to remember.
- If the user's own config has a mapping that does it, prefer and mention that mapping.
- Add at most 3 closely related tips. No headings, no long intros. Keep the whole answer under 15 lines.
- The leader key is <Space>. Neovim version is 0.12.]],
    context = function(mode)
      return table.concat({
        'Mode when asked: ' .. mode,
        'Filetype: ' .. (vim.bo.filetype ~= '' and vim.bo.filetype or 'none'),
        "Mappings in the user's config (mode lhs description):",
        user_keymaps(),
      }, '\n')
    end,
  },
  csharp = {
    title = 'Ask about C# / .NET',
    model = 'sonnet', -- Haiku made factual C# mistakes in testing; correctness beats a few seconds
    width = 100,
    system_prompt = [[
You answer quick questions about C# syntax and .NET APIs for a developer who knows Kotlin well and is new to C#.
Rules:
- Start with a short code snippet (```csharp) that answers the question directly, using modern C# (C# 14, .NET 10).
- Then explain in 1-4 short plain sentences what the unusual parts mean.
- When it helps, add one line "Kotlin: ..." with the closest Kotlin equivalent, and say where the analogy breaks.
- If the user's code is given and relevant, answer in terms of that code (its names and types).
- Mention one common pitfall if there is one. No headings, no long intros. Keep the whole answer under 25 lines.]],
    context = code_context,
  },
}

local function float(lines, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local width = math.min(opts.width or 80, vim.o.columns - 4)
  local height = math.min(math.max(opts.height or #lines, 1), vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = opts.title,
    title_pos = 'center',
  })
  vim.bo[buf].bufhidden = 'wipe'
  return buf, win
end

local function close(win)
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
end

local function show_answer(win, buf, text)
  if not vim.api.nvim_win_is_valid(win) then return end
  local lines = vim.split(vim.trim(text), '\n')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'markdown'
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  local height = 0
  local width = vim.api.nvim_win_get_width(win)
  for _, l in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  vim.api.nvim_win_set_config(win, {
    relative = 'editor',
    height = math.min(height, vim.o.lines - 6),
    row = math.floor((vim.o.lines - math.min(height, vim.o.lines - 6)) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })
end

local function ask(topic, question, context, history)
  local prompt = table.concat({
    '<context>',
    context,
    '</context>',
    history ~= '' and ('<previous_conversation>\n' .. history .. '\n</previous_conversation>') or '',
    'Question: ' .. question,
  }, '\n')

  local buf, win = float({ '  Thinking…' }, { title = ' ' .. question .. ' ', height = 1, width = topic.width })
  vim.keymap.set('n', 'q', function() close(win) end, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', function() close(win) end, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<CR>', function() close(win) end, { buffer = buf, nowait = true })

  vim.system({
    'claude',
    '-p',
    '--model',
    topic.model,
    '--tools',
    '',
    '--setting-sources',
    '',
    '--strict-mcp-config',
    '--no-session-persistence',
    '--system-prompt',
    topic.system_prompt,
  }, { stdin = prompt, text = true, cwd = vim.fn.stdpath 'cache' }, function(result)
    vim.schedule(function()
      local answer = result.code == 0 and result.stdout or ('Error from claude (exit ' .. result.code .. '):\n' .. (result.stderr or ''))
      show_answer(win, buf, answer)
      local new_history = history .. '\nQ: ' .. question .. '\nA: ' .. answer
      vim.keymap.set('n', 'a', function()
        close(win)
        M.prompt(topic, context, new_history)
      end, { buffer = buf, nowait = true, desc = 'Ask a follow-up' })
    end)
  end)
end

function M.prompt(topic, context, history)
  local buf, win = float({ '' }, { title = ' ' .. topic.title .. ' (Enter to send, Esc to cancel) ', height = 1, width = 70 })
  vim.cmd.startinsert()
  local function submit()
    local question = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or '')
    vim.cmd.stopinsert()
    close(win)
    if question ~= '' then ask(topic, question, context, history or '') end
  end
  vim.keymap.set({ 'i', 'n' }, '<CR>', submit, { buffer = buf })
  vim.keymap.set({ 'i', 'n' }, '<Esc>', function()
    vim.cmd.stopinsert()
    close(win)
  end, { buffer = buf })
end

-- Builds the context while still in the original buffer and mode, then leaves visual mode.
local function start(topic)
  return function()
    local mode = vim.api.nvim_get_mode().mode
    local context = topic.context(mode)
    -- Leave visual mode now; a queued <Esc> would run after startinsert and leave the prompt in normal mode.
    if mode:match '^[vV\22]' then vim.cmd.normal { vim.keycode '<Esc>', bang = true } end
    M.prompt(topic, context)
  end
end

vim.keymap.set({ 'n', 'x' }, '<leader>?', start(TOPICS.nvim), { desc = 'Ask Claude how to do something in Neovim [?]' })
vim.keymap.set({ 'n', 'x' }, '<leader>c', start(TOPICS.csharp), { desc = 'Ask Claude about [C]# syntax or API' })

return M
