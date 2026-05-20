# `codex-auth switch`

## Usage

```shell
codex-auth switch [--api|--skip-api]
codex-auth switch --live [--api|--skip-api]
codex-auth switch <query>
```

## Interactive Switch

`codex-auth switch` opens the account picker and exits after one successful switch.

- The picker uses the same account ordering as `list`.
- `q` quits without switching.
- Numbered fallback output is split into pages of at most 20 account rows.
- Click a table header to sort by that column; click the same header again to reverse the direction.
- `--api` forces foreground remote refresh before rendering.
- `--skip-api` renders from stored data and still refreshes the previously active account after a successful switch.
- Without `--api`, the picker renders from stored data.

## Live Switch

`codex-auth switch --live` keeps the picker open after each successful switch.

- The display refreshes on a timer.
- The picker shows at most 20 rows at once and uses Left/Right for page navigation.
- A successful switch patches the current display immediately.
- In-flight refresh results are discarded after a manual switch.
- Existing usage overlays stay visible until the next scheduled refresh.
- Click a table header to sort by that column; click the same header again to reverse the direction.

## Query Switch

`codex-auth switch <query>` resolves the target from stored local data.

Selectors can match:

- displayed row number,
- alias fragment,
- email fragment, or
- account name fragment.

If one account matches, it switches immediately. If multiple accounts match, the command falls back to interactive selection. Query mode does not accept `--live`, `--api`, or `--skip-api`.

## Switch Effects

When switching succeeds:

1. The previously active account is refreshed once through the usage API.
2. `auth.json` is backed up when its contents would change.
3. The selected account snapshot is copied to `~/.codex/auth.json`.
4. `active_account_key` is updated in `registry.json`.
