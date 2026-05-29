const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const me_api = @import("../api/me.zig");
const account_names = @import("account_names.zig");
const usage_refresh = @import("usage.zig");

const defaultAccountFetcher = account_names.defaultAccountFetcher;
const refreshAccountNamesAfterLogin = account_names.refreshAccountNamesAfterLogin;
const refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly = usage_refresh.refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly;

pub fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.LoginOptions) !void {
    const login_home = try createTempLoginCodexHome(allocator);
    defer {
        std.Io.Dir.cwd().deleteTree(app_runtime.io(), login_home) catch |err| {
            std.log.warn("failed to remove temporary Codex login home `{s}`: {s}", .{ login_home, @errorName(err) });
        };
        allocator.free(login_home);
    }

    try cli.login.runCodexLoginWithCodexHome(allocator, opts, login_home);
    const auth_path = try registry.activeAuthPath(allocator, login_home);
    defer allocator.free(auth_path);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    _ = try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg);

    if (info.auth_mode == .apikey) {
        const api_key = info.openai_api_key orelse return error.MissingOpenAiApiKey;
        var me = try me_api.fetchMeForApiKey(allocator, api_key);
        defer me.deinit(allocator);

        const record_key = try registry.apiKeyAccountKeyAlloc(allocator, me.user_id, api_key);
        defer allocator.free(record_key);
        const dest = try registry.accountAuthPath(allocator, codex_home, record_key);
        defer allocator.free(dest);

        try registry.ensureAccountsDir(allocator, codex_home);
        try registry.copyManagedFile(auth_path, dest);
        const active_auth_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(active_auth_path);
        try registry.copyManagedFile(auth_path, active_auth_path);

        const record = try registry.accountFromApiKeyMe(allocator, "", &info, &me);
        try registry.upsertAccount(allocator, &reg, record);
        try registry.setActiveAccountKey(allocator, &reg, record_key);
        try registry.saveRegistry(allocator, codex_home, &reg);
        return;
    }

    const email = info.email orelse return error.MissingEmail;
    _ = email;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;
    const dest = try registry.accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try registry.ensureAccountsDir(allocator, codex_home);
    try registry.copyManagedFile(auth_path, dest);
    const active_auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(active_auth_path);
    try registry.copyManagedFile(auth_path, active_auth_path);

    const record = try registry.accountFromAuth(allocator, "", &info);
    try registry.upsertAccount(allocator, &reg, record);
    _ = try registry.reconcileLegacyChatGptAccountId(allocator, codex_home, &reg, &info);
    try registry.setActiveAccountKey(allocator, &reg, record_key);
    registry.touchAccountUse(&reg, record_key);
    _ = registry.clearAccountLastUsageError(allocator, &reg, record_key);
    var usage_state = try refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly(
        allocator,
        codex_home,
        &reg,
        true,
        true,
    );
    defer usage_state.deinit(allocator);
    _ = try refreshAccountNamesAfterLogin(allocator, &reg, &info, defaultAccountFetcher);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn createTempLoginCodexHome(allocator: std.mem.Allocator) ![]u8 {
    const base = try tempBasePathAlloc(allocator);
    defer allocator.free(base);

    var counter: usize = 0;
    while (counter < 100) : (counter += 1) {
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}{c}codex-auth-login-{d}-{d}",
            .{
                base,
                std.fs.path.sep,
                std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds(),
                counter,
            },
        );
        const status = std.Io.Dir.cwd().createDirPathStatus(app_runtime.io(), path, .default_dir) catch |err| {
            allocator.free(path);
            return err;
        };
        if (status == .existed) {
            allocator.free(path);
            continue;
        }
        return path;
    }
    return error.PathAlreadyExists;
}

fn tempBasePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (try registry.getNonEmptyEnvVarOwned(allocator, "TEMP")) |path| return path;
        if (try registry.getNonEmptyEnvVarOwned(allocator, "TMP")) |path| return path;
        if (try registry.getNonEmptyEnvVarOwned(allocator, "TMPDIR")) |path| return path;
        return allocator.dupe(u8, "C:\\Temp");
    }

    if (try registry.getNonEmptyEnvVarOwned(allocator, "TMPDIR")) |path| return path;
    if (try registry.getNonEmptyEnvVarOwned(allocator, "TMP")) |path| return path;
    if (try registry.getNonEmptyEnvVarOwned(allocator, "TEMP")) |path| return path;
    return allocator.dupe(u8, "/tmp");
}
