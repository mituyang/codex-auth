const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");

const config_file_name = "switch.json";

pub const ForegroundApiConfig = struct {
    skip_api: bool = false,
};

const ForegroundApiConfigOut = struct {
    skip_api: bool,
};

pub fn foregroundApiConfigPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", config_file_name });
}

pub fn loadForegroundApiConfig(allocator: std.mem.Allocator, codex_home: []const u8) !ForegroundApiConfig {
    const path = try foregroundApiConfigPath(allocator, codex_home);
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

    var cfg = ForegroundApiConfig{};
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return cfg,
    };
    if (obj.get("skip_api")) |value| switch (value) {
        .bool => |skip_api| cfg.skip_api = skip_api,
        else => {},
    };
    return cfg;
}

pub fn saveForegroundApiConfig(allocator: std.mem.Allocator, codex_home: []const u8, cfg: ForegroundApiConfig) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    const path = try foregroundApiConfigPath(allocator, codex_home);
    defer allocator.free(path);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(ForegroundApiConfigOut{
        .skip_api = cfg.skip_api,
    }, .{ .whitespace = .indent_2 }, &aw.writer);
    try registry.writeFile(path, aw.written());
}

pub fn resolveForegroundApiMode(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    api_mode: cli.types.ApiMode,
) !cli.types.ApiMode {
    if (api_mode != .default) return api_mode;
    const cfg = try loadForegroundApiConfig(allocator, codex_home);
    return if (cfg.skip_api) .skip_api else .default;
}
