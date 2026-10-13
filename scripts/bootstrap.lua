-- Headless first-run setup, used by install.sh / install.ps1:
--   nvim --headless "+luafile scripts/bootstrap.lua"
-- Plugins are installed by vim.pack while init.lua loads; this waits for the
-- treesitter parsers and the Mason tools, then reports what is missing.

local function say(msg) io.write(msg .. '\n') end
local failed = false

-- Treesitter parsers (list comes from init.lua)
local parsers = vim.g.kickstart_parsers or {}
say('Installing treesitter parsers...')
require('nvim-treesitter').install(parsers):wait(15 * 60 * 1000)
local installed = require('nvim-treesitter').get_installed 'parsers'
for _, p in ipairs(parsers) do
  if not vim.tbl_contains(installed, p) then
    say('  MISSING parser: ' .. p)
    failed = true
  end
end

-- LSP servers and formatters (ensure_installed list in init.lua)
say('Installing Mason tools (language servers, formatters)...')
vim.cmd 'MasonToolsInstallSync'
say('  installed: ' .. table.concat(require('mason-registry').get_installed_package_names(), ', '))

-- Every enabled language server must have its executable available
-- (from Mason's bin dir, which mason puts on PATH, or a system install)
for name in pairs(vim.lsp._enabled_configs or {}) do
  local cfg = vim.lsp.config[name]
  local cmd = cfg and type(cfg.cmd) == 'table' and cfg.cmd[1]
  if cmd and vim.fn.executable(cmd) == 0 then
    say(('  MISSING executable for LSP %s: %s'):format(name, cmd))
    failed = true
  end
end

say(failed and 'Bootstrap finished with problems (see above, or run :checkhealth).' or 'Bootstrap complete.')
vim.cmd(failed and 'cquit 1' or 'qa!')
