const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const chatgpt_http = @import("../api/http.zig");
const registry = @import("../registry/root.zig");
const usage_refresh = @import("usage.zig");

pub fn refreshPreviousActiveUsageBeforeSwitch(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !void {
    const active_account_key = reg.active_account_key orelse return;
    const active_idx = registry.findAccountIndexByAccountKey(reg, active_account_key) orelse return;
    if (reg.accounts.items[active_idx].auth_mode != null and reg.accounts.items[active_idx].auth_mode.? == .apikey) return;

    const node_available = nodeExecutableAvailableSilently(allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    if (!node_available) return;

    var usage_state = usage_refresh.refreshForegroundUsageForDisplayWithBatchFetcherUsingApiEnabledAndActiveOnly(
        allocator,
        codex_home,
        reg,
        true,
        true,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer usage_state.deinit(allocator);
}

fn nodeExecutableAvailableSilently(allocator: std.mem.Allocator) !bool {
    const node_executable = try chatgpt_http.resolveNodeExecutableAlloc(allocator);
    defer allocator.free(node_executable);

    if (std.fs.path.isAbsolute(node_executable) or std.mem.indexOfAny(u8, node_executable, "/\\") != null) {
        return accessPath(node_executable);
    }

    const path_value = chatgpt_http.env.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    defer allocator.free(path_value);

    var path_it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (path_it.next()) |entry| {
        if (entry.len == 0) continue;
        const resolved = try chatgpt_http.resolveExecutablePathEntryForLaunchAlloc(allocator, entry, node_executable);
        if (resolved) |path| {
            allocator.free(path);
            return true;
        }
    }

    return false;
}

fn accessPath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(app_runtime.io(), path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(app_runtime.io(), path, .{}) catch return false;
    return true;
}
