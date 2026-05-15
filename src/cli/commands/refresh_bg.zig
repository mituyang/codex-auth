const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .refresh_bg } };
    }
    if (args.len != 1) return common.usageErrorResult(allocator, .refresh_bg, "`refresh-bg` requires `enable` or `disable`.", .{});

    const action = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, action, "enable")) return .{ .command = .{ .refresh_bg = .{ .action = .enable } } };
    if (std.mem.eql(u8, action, "disable")) return .{ .command = .{ .refresh_bg = .{ .action = .disable } } };
    if (std.mem.eql(u8, action, "run")) return .{ .command = .{ .refresh_bg = .{ .action = .run } } };
    if (std.mem.startsWith(u8, action, "-")) {
        return common.usageErrorResult(allocator, .refresh_bg, "unknown flag `{s}` for `refresh-bg`.", .{action});
    }
    return common.usageErrorResult(allocator, .refresh_bg, "unknown action `{s}` for `refresh-bg`.", .{action});
}
