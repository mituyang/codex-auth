# `codex-auth refresh-bg`

## Usage

```shell
codex-auth refresh-bg enable
codex-auth refresh-bg disable
```

## Behavior

`refresh-bg enable` starts background usage refresh.

`refresh-bg disable` stops background usage refresh after the current sleep or request finishes.

Background refresh uses the same API-backed usage refresh path as foreground commands. It refreshes one eligible ChatGPT account per interval, chooses randomly from the five accounts with the oldest `LAST ACTIVITY`, and skips API-key accounts.

If a background account refresh fails to return usage data, it waits 10 seconds and retries the same account up to three times before moving on to the next interval.

Configure the interval with:

```shell
codex-auth config refresh --interval 60
codex-auth config refresh --interval 60-70
```
