# `codex-auth list`

## Usage

```shell
codex-auth list
codex-auth list --active
codex-auth list --live
codex-auth list --api
codex-auth list --skip-api
```

## Behavior

- Lists stored accounts from `registry.json`.
- Syncs the current `auth.json` into the registry before rendering when the current auth file is parseable.
- Shows selectable row numbers using the same ordering as `switch` and `remove`.
- Groups rows by email when the same email owns multiple account snapshots.
- Shows `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, and `LAST ACTIVITY`.
- Static output and numbered tables are split into pages of at most 20 account rows.

## Refresh Modes

- Default mode performs foreground usage and account-name API refresh.
- `--active` refreshes usage only for the active account before rendering and skips account-name API refresh. Other rows use stored registry snapshots.
- `--api` is accepted as an explicit equivalent to default mode.
- `--skip-api` forbids remote API calls for this command.
- `codex-auth config switch --skip-api` makes plain `list` default to local-only mode.
- `--live` keeps refreshing the terminal view and requires a TTY.
- In a TTY, plain `list` opens a sortable table without scheduled live refresh. Without a TTY, it prints a static table.

When local-only refresh is active, only the active account can be updated from local rollout files. Non-active rows use the stored registry snapshot.

## Output Notes

- Alias labels render before the email when an alias exists.
- Usage cells show remaining percent and reset time when that data is known.
- Remote refresh failures can render row overlays such as `401`, `403`, `TimedOut`, or `MissingAuth`.
- `LAST ACTIVITY` is based on the last stored usage update time.
- In the interactive table, click a table header to sort by that column; click the same header again to reverse the direction.
- Interactive table views show at most 20 rows at once and use Left/Right for page navigation.
- When the interactive table exits, it prints the final visible table, preserving the current sort order.
- Shared table layout policy is documented in [docs/table-layout.md](../table-layout.md).
