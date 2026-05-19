# Audit Log

`codex-auth` writes command audit logs by default.

## Location

```text
~/.codex/logs/codex-auth.jsonl
```

When `CODEX_HOME` points to an existing directory, the log is written under:

```text
$CODEX_HOME/logs/codex-auth.jsonl
```

## Format

The log is JSON Lines. Each CLI invocation writes a `start` entry and a `finish` entry with the command name, arguments, process id where available, timestamps, duration, exit code, and handled error name.

Background refresh also writes `background_refresh` attempt entries with the selected account index, retry count, update status, failure status, and error name when an unexpected refresh error escapes the refresh round.

