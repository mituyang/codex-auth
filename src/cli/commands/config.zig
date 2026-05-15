const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len < 1) return common.usageErrorResult(allocator, .config, "`config` requires a section.", .{});
    const scope = std.mem.sliceTo(args[0], 0);

    if (std.mem.eql(u8, scope, "live")) {
        return parseLive(allocator, args[1..]);
    }
    if (std.mem.eql(u8, scope, "refresh")) {
        return parseRefresh(allocator, args[1..]);
    }
    return common.usageErrorResult(allocator, .config, "unknown config section `{s}`.", .{scope});
}

fn parseLive(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len != 2) return common.usageErrorResult(allocator, .config, "`config live` requires `--interval <seconds>`.", .{});
    const flag = std.mem.sliceTo(args[0], 0);
    if (!std.mem.eql(u8, flag, "--interval")) {
        if (std.mem.startsWith(u8, flag, "-")) {
            return common.usageErrorResult(allocator, .config, "unknown flag `{s}` for `config live`.", .{flag});
        }
        return common.usageErrorResult(allocator, .config, "unknown argument `{s}` for `config live`.", .{flag});
    }
    const raw = std.mem.sliceTo(args[1], 0);
    const interval = std.fmt.parseInt(u16, raw, 10) catch
        return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
    if (interval < 5 or interval > 3600) {
        return common.usageErrorResult(allocator, .config, "`--interval` must be an integer from 5 to 3600 seconds.", .{});
    }
    return .{ .command = .{ .config = .{ .live = .{ .interval_seconds = interval } } } };
}

fn parseRefresh(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .config } };
    }
    if (args.len != 2) return common.usageErrorResult(allocator, .config, "`config refresh` requires `--interval <seconds|range>`.", .{});
    const flag = std.mem.sliceTo(args[0], 0);
    if (!std.mem.eql(u8, flag, "--interval")) {
        if (std.mem.startsWith(u8, flag, "-")) {
            return common.usageErrorResult(allocator, .config, "unknown flag `{s}` for `config refresh`.", .{flag});
        }
        return common.usageErrorResult(allocator, .config, "unknown argument `{s}` for `config refresh`.", .{flag});
    }
    const raw = std.mem.sliceTo(args[1], 0);
    const interval = parseRefreshInterval(raw) catch
        return common.usageErrorResult(allocator, .config, "`--interval` must be an integer or range from 5 to 3600 seconds.", .{});
    return .{ .command = .{ .config = .{ .refresh = interval } } };
}

fn parseRefreshInterval(raw: []const u8) !types.RefreshOptions {
    if (std.mem.indexOfScalar(u8, raw, '-')) |sep| {
        const min = try parseRefreshIntervalPart(raw[0..sep]);
        const max = try parseRefreshIntervalPart(raw[sep + 1 ..]);
        if (min > max) return error.InvalidIntervalRange;
        return .{
            .interval_min_seconds = min,
            .interval_max_seconds = max,
        };
    }
    const seconds = try parseRefreshIntervalPart(raw);
    return .{
        .interval_min_seconds = seconds,
        .interval_max_seconds = seconds,
    };
}

fn parseRefreshIntervalPart(raw: []const u8) !u16 {
    const interval = try std.fmt.parseInt(u16, raw, 10);
    if (interval < 5 or interval > 3600) return error.InvalidIntervalRange;
    return interval;
}
