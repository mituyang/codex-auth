const std = @import("std");
const fs = @import("codex_auth").core.compat_fs;
const usage_api = @import("codex_auth").api.usage;
const registry = @import("codex_auth").registry;
const refresh_bg = @import("codex_auth").workflows.refresh_bg;

var retry_fetch_count: usize = 0;

fn makeRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    idx: usize,
    auth_mode: ?registry.AuthMode,
    last_usage_at: ?i64,
) !void {
    const account_key = try std.fmt.allocPrint(allocator, "user-{d}::account-{d}", .{ idx, idx });
    errdefer allocator.free(account_key);
    const chatgpt_account_id = try std.fmt.allocPrint(allocator, "account-{d}", .{idx});
    errdefer allocator.free(chatgpt_account_id);
    const chatgpt_user_id = try std.fmt.allocPrint(allocator, "user-{d}", .{idx});
    errdefer allocator.free(chatgpt_user_id);
    const email = try std.fmt.allocPrint(allocator, "user{d}@example.com", .{idx});
    errdefer allocator.free(email);
    const alias = try std.fmt.allocPrint(allocator, "alias-{d}", .{idx});
    errdefer allocator.free(alias);

    try reg.accounts.append(allocator, .{
        .account_key = account_key,
        .chatgpt_account_id = chatgpt_account_id,
        .chatgpt_user_id = chatgpt_user_id,
        .email = email,
        .alias = alias,
        .account_name = null,
        .plan = .team,
        .auth_mode = auth_mode,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = last_usage_at,
        .last_local_rollout = null,
    });
}

fn testSnapshot() registry.RateLimitSnapshot {
    return .{
        .primary = .{
            .used_percent = 10,
            .window_minutes = 300,
            .resets_at = null,
        },
        .secondary = .{
            .used_percent = 20,
            .window_minutes = 10080,
            .resets_at = null,
        },
        .credits = null,
        .plan_type = .team,
    };
}

test "background refresh selection chooses only from five stalest accounts" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    var idx: usize = 0;
    while (idx < 7) : (idx += 1) {
        try appendAccount(gpa, &reg, idx, .chatgpt, @as(i64, @intCast(idx + 1)));
    }

    var seed: u64 = 0;
    while (seed < 128) : (seed += 1) {
        const selected = refresh_bg.selectBackgroundRefreshAccountIndex(&reg, seed) orelse return error.TestExpectedEqual;
        try std.testing.expect(selected < 5);
    }
}

test "background refresh selection treats missing last activity as oldest" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, 0, .chatgpt, 100);
    try appendAccount(gpa, &reg, 1, .chatgpt, 200);
    try appendAccount(gpa, &reg, 2, .chatgpt, 300);
    try appendAccount(gpa, &reg, 3, .chatgpt, 400);
    try appendAccount(gpa, &reg, 4, .chatgpt, 500);
    try appendAccount(gpa, &reg, 5, .chatgpt, null);
    try appendAccount(gpa, &reg, 6, .chatgpt, null);

    var seed: u64 = 0;
    while (seed < 128) : (seed += 1) {
        const selected = refresh_bg.selectBackgroundRefreshAccountIndex(&reg, seed) orelse return error.TestExpectedEqual;
        try std.testing.expect(selected == 5 or selected == 6 or selected < 3);
    }
}

test "background refresh selection skips api key accounts" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    var idx: usize = 0;
    while (idx < 5) : (idx += 1) {
        try appendAccount(gpa, &reg, idx, .apikey, @as(i64, @intCast(idx + 1)));
    }
    try appendAccount(gpa, &reg, 5, .chatgpt, 999);

    const selected = refresh_bg.selectBackgroundRefreshAccountIndex(&reg, 42) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 5), selected);
}

test "background refresh interval selection returns fixed value for single interval" {
    const selected = refresh_bg.selectBackgroundRefreshIntervalSeconds(.{
        .interval_min_seconds = 60,
        .interval_max_seconds = 60,
    }, 42);
    try std.testing.expectEqual(@as(u16, 60), selected);
}

test "background refresh interval selection returns value within configured range" {
    var seed: u64 = 0;
    while (seed < 128) : (seed += 1) {
        const selected = refresh_bg.selectBackgroundRefreshIntervalSeconds(.{
            .interval_min_seconds = 60,
            .interval_max_seconds = 70,
        }, seed);
        try std.testing.expect(selected >= 60);
        try std.testing.expect(selected <= 70);
    }
}

test "background refresh updates last activity when api snapshot is unchanged" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, 0, .chatgpt, 1);
    reg.accounts.items[0].last_usage = testSnapshot();

    const Fetcher = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
            return .{
                .snapshot = testSnapshot(),
                .status_code = 200,
            };
        }
    };

    const result = try refresh_bg.refreshBackgroundAccountAtIndex(gpa, codex_home, &reg, 0, Fetcher.fetch);
    try std.testing.expect(result.attempted);
    try std.testing.expect(result.updated);
    try std.testing.expect(reg.accounts.items[0].last_usage_at != null);
    try std.testing.expect(reg.accounts.items[0].last_usage_at.? > 1);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(loaded.accounts.items[0].last_usage_at != null);
    try std.testing.expect(loaded.accounts.items[0].last_usage_at.? > 1);
}

test "background refresh retries failed fetches and updates on retry success" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, 0, .chatgpt, 1);

    retry_fetch_count = 0;
    const Fetcher = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
            retry_fetch_count += 1;
            if (retry_fetch_count < 3) return error.RequestFailed;
            return .{
                .snapshot = testSnapshot(),
                .status_code = 200,
            };
        }
    };

    const result = try refresh_bg.refreshBackgroundAccountAtIndexWithRetry(gpa, codex_home, &reg, 0, Fetcher.fetch, 3, 0);
    try std.testing.expect(result.attempted);
    try std.testing.expect(result.updated);
    try std.testing.expect(!result.failed);
    try std.testing.expectEqual(@as(u8, 3), result.attempts);
    try std.testing.expectEqual(@as(usize, 3), retry_fetch_count);
    try std.testing.expect(reg.accounts.items[0].last_usage_at != null);
    try std.testing.expect(reg.accounts.items[0].last_usage_at.? > 1);
}

test "background refresh stops after three retries when fetch keeps failing" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, 0, .chatgpt, 1);

    retry_fetch_count = 0;
    const Fetcher = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
            retry_fetch_count += 1;
            return .{
                .snapshot = null,
                .status_code = 500,
            };
        }
    };

    const result = try refresh_bg.refreshBackgroundAccountAtIndexWithRetry(gpa, codex_home, &reg, 0, Fetcher.fetch, 3, 0);
    try std.testing.expect(result.attempted);
    try std.testing.expect(!result.updated);
    try std.testing.expect(result.failed);
    try std.testing.expectEqual(@as(u8, 4), result.attempts);
    try std.testing.expectEqual(@as(usize, 4), retry_fetch_count);
    try std.testing.expect(reg.accounts.items[0].last_usage_at != null);
    try std.testing.expect(reg.accounts.items[0].last_usage_at.? > 1);
    try std.testing.expectEqualStrings("500", reg.accounts.items[0].last_usage_error.?);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqualStrings("500", loaded.accounts.items[0].last_usage_error.?);
    try std.testing.expect(loaded.accounts.items[0].last_usage_at != null);
}

test "background refresh persists token-expired status without response code text" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, 0, .chatgpt, 1);

    const Fetcher = struct {
        fn fetch(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
            return .{
                .snapshot = null,
                .status_code = 401,
                .error_code = usage_api.parseNonSuccessErrorCode(std.testing.allocator, 401,
                    \\{
                    \\  "error": {
                    \\    "message": "Provided authentication token is expired. Please try signing in again.",
                    \\    "type": "invalid_request_error",
                    \\    "param": null,
                    \\    "code": "token_expired"
                    \\  }
                    \\}
                ),
            };
        }
    };

    const result = try refresh_bg.refreshBackgroundAccountAtIndex(gpa, codex_home, &reg, 0, Fetcher.fetch);
    try std.testing.expect(result.attempted);
    try std.testing.expect(!result.updated);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("401", reg.accounts.items[0].last_usage_error.?);
    try std.testing.expect(reg.accounts.items[0].last_usage_at != null);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqualStrings("401", loaded.accounts.items[0].last_usage_error.?);
    try std.testing.expect(loaded.accounts.items[0].last_usage_at != null);
}
