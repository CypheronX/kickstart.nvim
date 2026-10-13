-- C# / .NET support
--
-- Language server: Microsoft's Roslyn LSP (same engine as VS Code's C# extension),
--  installed by Mason as `roslyn` (see the extra registry in init.lua) and started by roslyn.nvim.
--  roslyn.nvim finds the nearest .sln/.slnx/.csproj and loads it; with several solutions,
--  pick one with `:Roslyn target`.
-- Formatter: csharpier (`<leader>f`, configured in conform's formatters_by_ft).
-- Syntax: treesitter `c_sharp` parser (see the parser list in init.lua).

vim.pack.add { 'https://github.com/seblyng/roslyn.nvim' }

vim.lsp.config('roslyn', {
  settings = {
    ['csharp|inlay_hints'] = {
      csharp_enable_inlay_hints_for_implicit_object_creation = true,
      csharp_enable_inlay_hints_for_implicit_variable_types = true,
      csharp_enable_inlay_hints_for_lambda_parameter_types = true,
      csharp_enable_inlay_hints_for_types = true,
      dotnet_enable_inlay_hints_for_parameters = true,
    },
    ['csharp|code_lens'] = {
      dotnet_enable_references_code_lens = true,
    },
    ['csharp|completion'] = {
      dotnet_show_completion_items_from_unimported_namespaces = true,
      dotnet_show_name_completion_suggestions = true,
    },
    ['csharp|background_analysis'] = {
      dotnet_analyzer_diagnostics_scope = 'openFiles',
      dotnet_compiler_diagnostics_scope = 'fullSolution',
    },
  },
})

require('roslyn').setup {}
