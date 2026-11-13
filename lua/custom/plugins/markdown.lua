-- Markdown rendering inside the buffer
--
-- render-markdown.nvim draws headings, tables, code blocks, lists, checkboxes and callouts
--  in normal mode and shows the raw text on the line under the cursor (and in insert mode).
-- Needs the treesitter `markdown` and `markdown_inline` parsers (see the parser list in init.lua).
-- Icons come from mini.icons (part of mini.nvim, already installed).
-- `<leader>tm` toggles rendering; `:RenderMarkdown` lists other commands.

vim.pack.add { 'https://github.com/MeanderingProgrammer/render-markdown.nvim' }

require('render-markdown').setup {
  file_types = { 'markdown' },
  completions = { blink = { enabled = true } },
}

vim.keymap.set('n', '<leader>tm', '<cmd>RenderMarkdown toggle<CR>', { desc = '[T]oggle [M]arkdown rendering' })
