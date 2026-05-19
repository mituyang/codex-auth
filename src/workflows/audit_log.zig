const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");

pub const command_log_file_name = "codex-auth.jsonl";

pub const CommandAudit = struct {
    path: ?[]u8 = null,
    started_at_ms: i64 = 0,

    pub fn deinit(self: *CommandAudit, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const CommandLogEntry = struct {
    schema_version: u8,
    kind: []const u8,
    event: []const u8,
    timestamp_ms: i64,
    started_at_ms: ?i64,
    duration_ms: ?i64,
    pid: ?i64,
    command: []const u8,
    argv: []const []const u8,
    exit_code: ?u8,
    @"error": ?[]const u8,
};

const BackgroundRefreshLogEntry = struct {
    schema_version: u8,
    kind: []const u8,
    event: []const u8,
    timestamp_ms: i64,
    pid: ?i64,
    account_index: ?usize,
    attempted: bool,
    updated: bool,
    failed: bool,
    attempts: u8,
    @"error": ?[]const u8,
};

pub const BackgroundRefreshLogAttempt = struct {
    account_index: ?usize = null,
    attempted: bool = false,
    updated: bool = false,
    failed: bool = false,
    attempts: u8 = 0,
    error_name: ?[]const u8 = null,
};

pub fn commandLogPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "logs", command_log_file_name });
}

pub fn beginCommandBestEffort(allocator: std.mem.Allocator, args: []const [:0]const u8) CommandAudit {
    const audit = CommandAudit{
        .path = resolveCommandLogPathBestEffort(allocator),
        .started_at_ms = nowMilliseconds(),
    };
    if (audit.path) |path| {
        appendCommandEvent(allocator, path, args, "start", audit.started_at_ms, null, null, null) catch {};
    }
    return audit;
}

pub fn finishCommandBestEffort(
    allocator: std.mem.Allocator,
    audit: *CommandAudit,
    args: []const [:0]const u8,
    exit_code: ?u8,
    error_name: ?[]const u8,
) void {
    defer audit.deinit(allocator);
    const path = audit.path orelse return;
    const finished_at_ms = nowMilliseconds();
    const duration_ms = if (finished_at_ms >= audit.started_at_ms) finished_at_ms - audit.started_at_ms else 0;
    appendCommandEvent(allocator, path, args, "finish", finished_at_ms, audit.started_at_ms, duration_ms, .{
        .exit_code = exit_code,
        .error_name = error_name,
    }) catch {};
}

pub fn appendBackgroundRefreshAttemptBestEffort(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    attempt: BackgroundRefreshLogAttempt,
) void {
    const path = commandLogPath(allocator, codex_home) catch return;
    defer allocator.free(path);
    appendBackgroundRefreshAttempt(allocator, path, attempt) catch {};
}

fn resolveCommandLogPathBestEffort(allocator: std.mem.Allocator) ?[]u8 {
    const codex_home = resolveCodexHomeForAudit(allocator) catch return null;
    defer allocator.free(codex_home);
    return commandLogPath(allocator, codex_home) catch null;
}

fn resolveCodexHomeForAudit(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try app_runtime.currentEnviron().createMap(allocator);
    defer env_map.deinit();

    if (env_map.get("CODEX_HOME")) |path| {
        if (path.len != 0) {
            const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch return error.EnvironmentVariableNotFound;
            if (stat.kind != .directory) return error.EnvironmentVariableNotFound;
            return try registry.realPathAlloc(allocator, path);
        }
    }
    if (env_map.get("HOME")) |path| {
        if (path.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ path, ".codex" });
    }
    if (env_map.get("USERPROFILE")) |path| {
        if (path.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ path, ".codex" });
    }
    return error.EnvironmentVariableNotFound;
}

const FinishFields = struct {
    exit_code: ?u8,
    error_name: ?[]const u8,
};

fn appendCommandEvent(
    allocator: std.mem.Allocator,
    path: []const u8,
    raw_args: []const [:0]const u8,
    event: []const u8,
    timestamp_ms: i64,
    started_at_ms: ?i64,
    duration_ms: ?i64,
    finish: ?FinishFields,
) !void {
    const argv = try argvToSlicesAlloc(allocator, raw_args);
    defer allocator.free(argv);

    const entry = CommandLogEntry{
        .schema_version = 1,
        .kind = "command",
        .event = event,
        .timestamp_ms = timestamp_ms,
        .started_at_ms = started_at_ms,
        .duration_ms = duration_ms,
        .pid = currentPid(),
        .command = commandNameFromArgs(raw_args),
        .argv = argv,
        .exit_code = if (finish) |fields| fields.exit_code else null,
        .@"error" = if (finish) |fields| fields.error_name else null,
    };
    try appendJsonLine(allocator, path, entry);
}

fn appendBackgroundRefreshAttempt(
    allocator: std.mem.Allocator,
    path: []const u8,
    attempt: BackgroundRefreshLogAttempt,
) !void {
    const entry = BackgroundRefreshLogEntry{
        .schema_version = 1,
        .kind = "background_refresh",
        .event = "attempt",
        .timestamp_ms = nowMilliseconds(),
        .pid = currentPid(),
        .account_index = attempt.account_index,
        .attempted = attempt.attempted,
        .updated = attempt.updated,
        .failed = attempt.failed,
        .attempts = attempt.attempts,
        .@"error" = attempt.error_name,
    };
    try appendJsonLine(allocator, path, entry);
}

fn argvToSlicesAlloc(allocator: std.mem.Allocator, args: []const [:0]const u8) ![][]const u8 {
    const argv = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, idx| {
        argv[idx] = std.mem.sliceTo(arg, 0);
    }
    return argv;
}

pub fn commandNameFromArgs(args: []const [:0]const u8) []const u8 {
    if (args.len < 2) return "help";
    const raw = std.mem.sliceTo(args[1], 0);
    if (std.mem.eql(u8, raw, "--version") or std.mem.eql(u8, raw, "-V")) return "version";
    if (std.mem.eql(u8, raw, "--help") or std.mem.eql(u8, raw, "-h")) return "help";
    return raw;
}

fn appendJsonLine(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.BadPathName;
    try registry.ensurePrivateDir(dir_path);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    try appendBytes(path, aw.written());
}

fn appendBytes(path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .permissions = registry.private_file_permissions,
    });
    defer file.close(app_runtime.io());

    const offset = try file.length(app_runtime.io());
    try file.writePositionalAll(app_runtime.io(), data, offset);
    try registry.hardenSensitiveFile(path);
}

fn nowMilliseconds() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds();
}

fn currentPid() ?i64 {
    if (comptime builtin.os.tag == .windows) return null;
    return @as(i64, @intCast(std.c.getpid()));
}
