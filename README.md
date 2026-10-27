# intellij-formatter.nvim

IntelliJ-powered formatting through [conform.nvim](https://github.com/stevearc/conform.nvim),
with EditorConfig support, Java import cleanup, and a reusable background daemon.

Uses the standalone [IntelliJ Headless Formatter](https://github.com/javanoo6/intellij-code-formatter).
An IntelliJ installation or language server is not required.

## Requirements

- Neovim 0.10+.
- JDK 21 on PATH, or an explicit `java` executable.
- [conform.nvim](https://github.com/stevearc/conform.nvim).
- For managed engine installation: `curl` and one of `sha256sum`, `shasum`,
  `openssl`, or Windows `certutil`. A local JAR can be used instead.

The pinned engine is 0.0.8. The initial download is about 347 MiB; the engine
extracts a larger IntelliJ runtime into the system temporary directory on first
use. The first formatting request downloads and verifies the engine automatically,
then finishes formatting. Later requests reuse the local JAR and work offline.

## Installation

### lazy.nvim / LazyVim

Add this spec to your plugin list, or put it in
`lua/plugins/intellij-formatter.lua` when importing that directory:

```lua
return {
  "javanoo6/intellij-formatter.nvim",
  dependencies = { "stevearc/conform.nvim" },
  event = { "BufReadPre", "BufNewFile" },
  keys = {
    { "<leader>cf", "<cmd>IntellijFormat<cr>", desc = "Format with IntelliJ" },
  },
  opts = { format_on_save = true },
}
```

Run `:Lazy sync`, open a supported file, and save it or press `<leader>cf`.
The first request shows a download notification and installs the verified engine
into `stdpath("data")/intellij-formatter/0.0.8/`. No install command or Maven build
is needed. Concurrent requests share the download and continue when it is ready.
If a buffer changes during installation, its queued request is discarded so newer
edits stay intact; the installed engine is ready for the next formatting request.

If Conform already owns format-on-save in your config, use `opts = {}` to avoid
duplicate save hooks. Manual formatting still uses `<leader>cf` or `:IntellijFormat`.

### vim-plug or native packages

Install both repositories with your preferred manager:

```vim
Plug 'stevearc/conform.nvim'
Plug 'javanoo6/intellij-formatter.nvim'
```

Then configure them from `init.lua`:

```lua
require("intellij-formatter").setup({})
```

The engine installs automatically when formatting is first requested. For native
packages, clone both repositories into a directory on `packpath` and use the same
setup call. Use `format_on_save = true` if you want formatting whenever you save.

## Supported filetypes

| Language | Neovim filetypes / files                    |
|----------|---------------------------------------------|
| Java     | `java`                                      |
| Python   | `python`: `.py`, `.pyw`, `.pyi`             |
| JSON     | `json`, `jsonc`, `json5`                    |
| YAML     | `yaml`: `.yaml`, `.yml`; `yaml.helm-values` |
| Shell    | `sh`: `.sh`, `.bash`, shell shebangs; `zsh` |
| Markup   | `xml`, `xslt`, `html`, `xhtml`              |
| Markdown | `markdown`                                  |
| TOML     | `toml`                                      |

`setup()` routes these types through `intellij_formatter` in Conform and disables
LSP fallback for them. Other filetypes keep their configured formatters.
Helm template buffers (`helm`) are excluded; plain YAML values are supported.

Full-file Java formatting also removes unused imports and rearranges members.
Range formatting omits both cleanup operations. Python import sorting and
unused-import removal are not supported by the standalone engine.

Shell formatting uses bundled shfmt 3.14.1. No Python interpreter, shfmt
installation, or IntelliJ project import is needed. Shell binaries cover Linux
and macOS on AMD64/ARM64, and Windows on AMD64. The plugin integration is tested
on Linux; the other operating systems have not been validated here.

## Usage

```vim
:IntellijFormat
:'<,'>IntellijFormat
:IntellijFormatterInfo
:checkhealth intellij-formatter
:IntellijFormatterStop
```

`IntellijFormat` formats the current buffer asynchronously. A supplied line
range uses Conform's filtered diff hunks. Adjacent changes within an intersecting
hunk can extend past the selection; this is not native IntelliJ range formatting.
The engine formats a temporary copy; unsaved buffer contents are
included, and your source file is saved only by your normal write operation.
Conform rejects stale async results when the buffer changes during formatting.

The daemon is reused by default. Requests with whitespace in the file or explicit
EditorConfig path automatically use one-shot mode because the pinned engine's
daemon protocol cannot encode those paths. Set `daemon = false` to always use
one-shot formatting.

## Configuration

```lua
require("intellij-formatter").setup({
  -- Optional local build: skips managed engine installation.
  -- jar = "/path/to/formatter-cli-full.jar",
  java = "java", -- Or "/path/to/jdk-21/bin/java".

  -- Omit to discover .editorconfig from each file's location.
  -- editorconfig = vim.fn.stdpath("config") .. "/.editorconfig",

  timeout_ms = 30000, -- Includes the first engine extraction and JVM startup.
  auto_install = true, -- Download the verified engine on the first request.
  install_timeout_ms = 240000, -- Additional allowance while installing.
  daemon = true,
  optimize_imports = true, -- Java full-file requests only.
  rearrange = true, -- Java full-file requests only.
  format_on_save = false,
  conform = true,
  notify = true,

  -- Omit for all supported filetypes, or choose a subset:
  -- filetypes = { "java", "python", "yaml", "sh" },
})
```

`editorconfig` may also be a function receiving Conform's context and returning
a path or `nil`. An explicit path makes the engine apply that config's directory
as its style root, including when formatting files outside it.

The installer pins both `version` and `sha256`. To select a different engine
release, supply both values; get the checksum from that release's `SHA256SUMS`.
Set `auto_install = false` to prevent automatic downloads. You can still use
`:IntellijFormatterInstall` to install ahead of time or `:IntellijFormatterInstall!`
to redownload and verify a managed installation. A configured local `jar` is
never replaced automatically or by the install command.

### Use an existing Conform configuration

You can leave `conform = true` and retain your current format-on-save callback:
setup changes only supported filetype routes. The formatter has no dependency
on an IntelliJ LSP client. Those routes inherit `timeout_ms` unless your Conform
call supplies a timeout explicitly. The first request gets an additional download
allowance; cached requests use the normal formatting timeout. If your own Conform
callback passes a timeout explicitly, use `formatter.timeout()` for the same
behavior rather than a short fixed timeout.
If you need to own every route yourself:

```lua
local formatter = require("intellij-formatter")
formatter.setup({ conform = false })

require("conform").setup({
  formatters = {
    intellij_formatter = formatter.conform_formatter(),
  },
  formatters_by_ft = {
    java = { "intellij_formatter", lsp_format = "never" },
    python = { "intellij_formatter", lsp_format = "never" },
  },
})
```

Conform makes the formatter available when the JAR is installed or can be
installed automatically. Inspecting formatter availability does not download
anything. Missing Java, installation failures, and checksum mismatches produce
an error and preserve buffer contents. `formatter.available()` reports whether
the Java executable and JAR are already present; it does not start installation.

### Lua API

```lua
local formatter = require("intellij-formatter")
formatter.format({ bufnr = 0, async = false }, function(err, did_edit)
  -- Handle completion.
end)
formatter.install({}, function(err, path) end)
formatter.stop(function(err) end)
formatter.available() -- Boolean, plus an error string when unavailable.
formatter.ensure(function(err, path) end) -- Install automatically if needed.
formatter.timeout() -- Formatting timeout plus any first-install allowance.
formatter.jar_path()
formatter.filetypes() -- A copy of the configured filetype list.
formatter.supports("yaml")
formatter.info() -- Printable configuration report.
```

## Tests

```sh
make test
CONFORM_PATH=/path/to/conform.nvim make integration
```

Unit tests run without external plugins or network access. Integration tests
trigger automatic installation of the real engine, then exercise formatting, EditorConfig,
Java cleanup, ranges, whitespace paths, invalid scripts, stale async requests,
format-on-save, and idempotence. To reuse an existing engine instead:

```sh
CONFORM_PATH=/path/to/conform.nvim \
FORMATTER_JAR=/path/to/formatter-cli-full.jar make integration
```

## License

MIT for this Lua integration. The formatter engine and its bundled components
are distributed separately by their respective projects.
