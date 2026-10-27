# Changelog

## 0.1.1

- Pin engine 0.0.8, which fixes intermittent Java import cleanup failures during cold startup.
- Allow 30 seconds for initial runtime extraction and JVM startup.
- Apply the configured timeout to direct Conform calls as well as plugin commands.
- Add direct Conform integration coverage.

## 0.1.0

- Initial IntelliJ formatter integration with managed engine installation, EditorConfig,
  Java cleanup, Conform routes, commands, health checks, and optional format-on-save.
