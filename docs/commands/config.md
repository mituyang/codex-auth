# `codex-auth config`

## Usage

```shell
codex-auth config live --interval <seconds>
codex-auth config refresh --interval <seconds|range>
```

## Live Refresh Config

`config live --interval <seconds>` sets the live TUI refresh interval.

- Allowed range: `5` to `3600`.
- Stored in `registry.json` as top-level `interval_seconds`.

## Background Refresh Config

`config refresh --interval <seconds|range>` sets the background usage refresh interval.

- Allowed range: `5` to `3600`.
- Single value example: `60`.
- Range example: `60-70`, which chooses a random delay from `60` to `70` seconds between background refresh attempts.
- The interval is the delay between background account refresh attempts.
- Stored in `accounts/refresh-bg.json` as `interval_min_seconds` and `interval_max_seconds`.
- The command prints the current background refresh enabled/disabled status after saving the interval.
- When background refresh is already enabled, the command also starts the background loop if it is not running.
- Use `codex-auth refresh-bg enable` and `codex-auth refresh-bg disable` to start or stop background refresh.

## API Refresh

API-backed refresh is the default for supported foreground paths. Use per-command `--skip-api` to run a foreground command with local data only. Older `registry.json` files may contain an `api` object; current builds ignore it and omit it on the next registry save.

API behavior and endpoint details live in [docs/api.md](../api.md).
