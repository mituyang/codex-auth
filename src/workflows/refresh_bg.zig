const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const cli = @import("../cli/root.zig");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");
const usage_api = @import("../api/usage.zig");

const config_file_name = "refresh-bg.json";
const lock_file_name = "refresh-bg.lock";
const max_stale_candidate_count: usize = 5;

pub const RefreshBackgroundConfig = struct {
    enabled: bool = false,
    interval_min_seconds: u16 = registry.default_live_refresh_interval_seconds,
    interval_max_seconds: u16 = registry.default_live_refresh_interval_seconds,
};

const RefreshBackgroundConfigOut = struct {
    enabled: bool,
    interval_min_seconds: u16,
    interval_max_seconds: u16,
};

pub const BackgroundRefreshAttempt = struct {
    account_index: ?usize = null,
    attempted: bool = false,
    updated: bool = false,
    failed: bool = false,
};

pub const UsageFetcher = *const fn (
    allocator: std.mem.Allocator,
    auth_path: []const u8,
) anyerror!usage_api.UsageFetchResult;

pub fn handleRefreshBg(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.RefreshBgOptions) !void {
    switch (opts.action) {
        .enable => try enableRefreshBackground(allocator, codex_home),
        .disable => try disableRefreshBackground(allocator, codex_home),
        .run => try runRefreshBackground(allocator, codex_home),
    }
}

pub fn configureRefreshInterval(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.RefreshOptions) !void {
    var cfg = try loadRefreshBackgroundConfig(allocator, codex_home);
    const was_enabled = cfg.enabled;
    if (was_enabled) {
        cfg.enabled = false;
        try saveRefreshBackgroundConfig(allocator, codex_home, cfg);
        _ = try waitForRefreshBackgroundStop(allocator, codex_home);
    }

    cfg.interval_min_seconds = opts.interval_min_seconds;
    cfg.interval_max_seconds = opts.interval_max_seconds;
    cfg.enabled = was_enabled;
    try saveRefreshBackgroundConfig(allocator, codex_home, cfg);
    if (cfg.enabled) try startRefreshBackgroundProcess(allocator);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (cfg.interval_min_seconds == cfg.interval_max_seconds) {
        try out.print("Background refresh interval: {d}s\n", .{cfg.interval_min_seconds});
    } else {
        try out.print("Background refresh interval: {d}-{d}s\n", .{ cfg.interval_min_seconds, cfg.interval_max_seconds });
    }
    try out.print("Background refresh: {s}\n", .{if (cfg.enabled) "enabled" else "disabled"});
    try out.flush();
}

fn enableRefreshBackground(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var cfg = try loadRefreshBackgroundConfig(allocator, codex_home);
    cfg.enabled = true;
    try saveRefreshBackgroundConfig(allocator, codex_home, cfg);
    startRefreshBackgroundProcess(allocator) catch |err| {
        cfg.enabled = false;
        try saveRefreshBackgroundConfig(allocator, codex_home, cfg);
        return err;
    };
    try printRefreshBgLine("Background refresh enabled.\n");
}

fn disableRefreshBackground(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var cfg = try loadRefreshBackgroundConfig(allocator, codex_home);
    cfg.enabled = false;
    try saveRefreshBackgroundConfig(allocator, codex_home, cfg);
    _ = try waitForRefreshBackgroundStop(allocator, codex_home);
    try printRefreshBgLine("Background refresh disabled.\n");
}

fn printRefreshBgLine(message: []const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.writeAll(message);
    try out.flush();
}

pub fn refreshBackgroundConfigPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", config_file_name });
}

fn refreshBackgroundLockPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", lock_file_name });
}

pub fn loadRefreshBackgroundConfig(allocator: std.mem.Allocator, codex_home: []const u8) !RefreshBackgroundConfig {
    const path = try refreshBackgroundConfigPath(allocator, codex_home);
    defer allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(app_runtime.io());

    const data = try registry.readFileAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return .{};
    defer parsed.deinit();

    var cfg = RefreshBackgroundConfig{};
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return cfg,
    };
    if (obj.get("enabled")) |value| switch (value) {
        .bool => |enabled| cfg.enabled = enabled,
        else => {},
    };
    const min_value = if (obj.get("interval_min_seconds")) |value| parseRefreshIntervalSeconds(value) else null;
    const max_value = if (obj.get("interval_max_seconds")) |value| parseRefreshIntervalSeconds(value) else null;
    if (min_value != null and max_value != null and min_value.? <= max_value.?) {
        cfg.interval_min_seconds = min_value.?;
        cfg.interval_max_seconds = max_value.?;
    } else if (obj.get("interval_seconds")) |value| {
        if (parseRefreshIntervalSeconds(value)) |interval| {
            cfg.interval_min_seconds = interval;
            cfg.interval_max_seconds = interval;
        }
    }
    return cfg;
}

pub fn saveRefreshBackgroundConfig(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    cfg: RefreshBackgroundConfig,
) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    const path = try refreshBackgroundConfigPath(allocator, codex_home);
    defer allocator.free(path);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(RefreshBackgroundConfigOut{
        .enabled = cfg.enabled,
        .interval_min_seconds = cfg.interval_min_seconds,
        .interval_max_seconds = cfg.interval_max_seconds,
    }, .{ .whitespace = .indent_2 }, &aw.writer);
    try registry.writeFile(path, aw.written());
}

fn parseRefreshIntervalSeconds(v: std.json.Value) ?u16 {
    const raw = switch (v) {
        .integer => |i| i,
        else => return null,
    };
    if (raw < registry.min_live_refresh_interval_seconds or raw > registry.max_live_refresh_interval_seconds) return null;
    return @as(u16, @intCast(raw));
}

fn startRefreshBackgroundProcess(allocator: std.mem.Allocator) !void {
    const exe = try std.process.executablePathAlloc(app_runtime.io(), allocator);
    defer allocator.free(exe);

    _ = try std.process.spawn(app_runtime.io(), .{
        .argv = &[_][]const u8{ exe, "refresh-bg", "run" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
}

fn detachFromTerminalBestEffort() void {
    if (comptime builtin.os.tag == .windows) return;
    _ = std.c.setsid();
}

fn runRefreshBackground(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    detachFromTerminalBestEffort();
    try registry.ensureAccountsDir(allocator, codex_home);
    const lock_path = try refreshBackgroundLockPath(allocator, codex_home);
    defer allocator.free(lock_path);

    var lock_file = std.Io.Dir.cwd().createFile(app_runtime.io(), lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = registry.private_file_permissions,
    }) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
    defer lock_file.close(app_runtime.io());

    while (true) {
        const cfg = try loadRefreshBackgroundConfig(allocator, codex_home);
        if (!cfg.enabled) return;
        _ = refreshOneBackgroundAccount(allocator, codex_home, usage_api.fetchUsageForAuthPathDetailed) catch {};
        if (!(try sleepRefreshIntervalOrDisabled(allocator, codex_home, selectBackgroundRefreshIntervalSeconds(cfg, randomSeed())))) return;
    }
}

fn waitForRefreshBackgroundStop(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try canAcquireRefreshBackgroundLock(allocator, codex_home)) return true;
        try app_runtime.io().sleep(.fromMilliseconds(100), .awake);
    }
    return false;
}

fn canAcquireRefreshBackgroundLock(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    try registry.ensureAccountsDir(allocator, codex_home);
    const lock_path = try refreshBackgroundLockPath(allocator, codex_home);
    defer allocator.free(lock_path);

    var lock_file = std.Io.Dir.cwd().createFile(app_runtime.io(), lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = registry.private_file_permissions,
    }) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    lock_file.close(app_runtime.io());
    return true;
}

pub fn selectBackgroundRefreshIntervalSeconds(cfg: RefreshBackgroundConfig, seed: u64) u16 {
    if (cfg.interval_min_seconds >= cfg.interval_max_seconds) return cfg.interval_min_seconds;
    var prng = std.Random.DefaultPrng.init(seed);
    const span = @as(u32, cfg.interval_max_seconds) - @as(u32, cfg.interval_min_seconds) + 1;
    const offset = prng.random().uintLessThan(u32, span);
    return cfg.interval_min_seconds + @as(u16, @intCast(offset));
}

fn sleepRefreshIntervalOrDisabled(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    interval_seconds: u16,
) !bool {
    var remaining = interval_seconds;
    while (remaining > 0) : (remaining -= 1) {
        try app_runtime.io().sleep(.fromSeconds(1), .awake);
        const cfg = try loadRefreshBackgroundConfig(allocator, codex_home);
        if (!cfg.enabled) return false;
    }
    return true;
}

pub fn refreshOneBackgroundAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    usage_fetcher: UsageFetcher,
) !BackgroundRefreshAttempt {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const account_idx = selectBackgroundRefreshAccountIndex(&reg, randomSeed()) orelse return .{};
    return refreshBackgroundAccountAtIndex(allocator, codex_home, &reg, account_idx, usage_fetcher);
}

pub fn refreshBackgroundAccountAtIndex(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_idx: usize,
    usage_fetcher: UsageFetcher,
) !BackgroundRefreshAttempt {
    if (account_idx >= reg.accounts.items.len) return error.AccountNotFound;
    const account_key = reg.accounts.items[account_idx].account_key;
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);

    const fetch_result = usage_fetcher(allocator, auth_path) catch return .{
        .account_index = account_idx,
        .attempted = true,
        .failed = true,
    };
    if (fetch_result.snapshot) |snapshot| {
        registry.updateUsage(allocator, reg, account_key, snapshot);
        try registry.saveRegistry(allocator, codex_home, reg);
        return .{
            .account_index = account_idx,
            .attempted = true,
            .updated = true,
        };
    }

    return .{
        .account_index = account_idx,
        .attempted = true,
    };
}

pub fn selectBackgroundRefreshAccountIndex(reg: *const registry.Registry, seed: u64) ?usize {
    var candidates: [max_stale_candidate_count]usize = undefined;
    var candidate_count: usize = 0;

    for (reg.accounts.items, 0..) |*rec, idx| {
        if (!isRefreshEligible(rec)) continue;
        insertStaleCandidate(reg, &candidates, &candidate_count, idx);
    }
    if (candidate_count == 0) return null;

    var prng = std.Random.DefaultPrng.init(seed);
    const choice = prng.random().uintLessThan(usize, candidate_count);
    return candidates[choice];
}

fn isRefreshEligible(rec: *const registry.AccountRecord) bool {
    if (rec.auth_mode) |mode| return mode == .chatgpt;
    return true;
}

fn insertStaleCandidate(
    reg: *const registry.Registry,
    candidates: *[max_stale_candidate_count]usize,
    candidate_count: *usize,
    idx: usize,
) void {
    const insert_at = staleInsertIndex(reg, candidates[0..candidate_count.*], idx) orelse return;
    if (candidate_count.* < max_stale_candidate_count) candidate_count.* += 1;

    var pos = candidate_count.*;
    while (pos > insert_at + 1) : (pos -= 1) {
        candidates[pos - 1] = candidates[pos - 2];
    }
    candidates[insert_at] = idx;
}

fn staleInsertIndex(reg: *const registry.Registry, candidates: []const usize, idx: usize) ?usize {
    for (candidates, 0..) |candidate_idx, pos| {
        if (staleAccountLessThan(reg, idx, candidate_idx)) return pos;
    }
    return if (candidates.len < max_stale_candidate_count) candidates.len else null;
}

fn staleAccountLessThan(reg: *const registry.Registry, lhs_idx: usize, rhs_idx: usize) bool {
    const lhs = &reg.accounts.items[lhs_idx];
    const rhs = &reg.accounts.items[rhs_idx];
    const lhs_last = lhs.last_usage_at;
    const rhs_last = rhs.last_usage_at;
    if (lhs_last == null and rhs_last != null) return true;
    if (lhs_last != null and rhs_last == null) return false;
    if (lhs_last != null and rhs_last != null and lhs_last.? != rhs_last.?) return lhs_last.? < rhs_last.?;
    return std.mem.lessThan(u8, lhs.account_key, rhs.account_key);
}

fn randomSeed() u64 {
    const ns = std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds();
    return @as(u64, @truncate(@as(u128, @intCast(ns))));
}
