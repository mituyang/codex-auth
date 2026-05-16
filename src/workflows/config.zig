const std = @import("std");
const cli = @import("../cli/root.zig");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");
const foreground_api_config = @import("foreground_api_config.zig");
const refresh_bg = @import("refresh_bg.zig");

pub fn handleConfig(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ConfigOptions) !void {
    switch (opts) {
        .live => |live_opts| try handleLiveCommand(allocator, codex_home, live_opts),
        .refresh => |refresh_opts| try refresh_bg.configureRefreshInterval(allocator, codex_home, refresh_opts),
        .switch_account => |switch_opts| try handleSwitchCommand(allocator, codex_home, switch_opts),
    }
}

fn handleLiveCommand(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.LiveOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    reg.live.interval_seconds = opts.interval_seconds;
    try registry.saveRegistry(allocator, codex_home, &reg);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print("Live refresh interval: {d}s\n", .{opts.interval_seconds});
    try out.flush();
}

fn handleSwitchCommand(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.SwitchConfigOptions) !void {
    const cfg: foreground_api_config.ForegroundApiConfig = .{
        .skip_api = opts.api_mode == .skip_api,
    };
    try foreground_api_config.saveForegroundApiConfig(allocator, codex_home, cfg);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print("Foreground API default: {s}\n", .{if (cfg.skip_api) "skip-api" else "api"});
    try out.flush();
}
