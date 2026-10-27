# Changelog

## 0.2.0

- Automatically download and verify the engine on the first formatting request.
- Continue queued formatting after installation, including direct Conform calls and format-on-save.
- Share concurrent downloads and serialize engine requests to protect initial runtime setup.
- Preserve newer buffer edits and safely report failed downloads or checksum checks.
- Add a first-install timeout allowance and an `auto_install = false` opt-out.
- Simplify the recommended installation to plugin setup followed by ordinary formatting.

## 0.1.1

- Pin engine 0.0.8, which fixes intermittent Java import cleanup failures during cold startup.
- Allow 30 seconds for initial runtime extraction and JVM startup.
- Apply the configured timeout to direct Conform calls as well as plugin commands.
- Add direct Conform integration coverage.

## 0.1.0

- Initial IntelliJ formatter integration with managed engine installation, EditorConfig,
  Java cleanup, Conform routes, commands, health checks, and optional format-on-save.
