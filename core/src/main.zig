const std = @import("std");

const SpscQueue = @import("spsc_queue").SpscQueue;

const common = @import("graphite-common");
const game = @import("game.zig");
const server = @import("server.zig");
const uring = @import("uring.zig");

const VanillaModule = @import("module/vanilla.zig").VanillaModule(.{
    .send_join_message = true,
    .send_quit_message = true,
});
const LogModule = @import("module/log.zig").LogModule(.{});

pub const Modules = .{
    VanillaModule,
    LogModule,
};

pub const ModuleRegistry = common.ModuleRegistry(Modules);

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    const ttyconf = std.Io.tty.Config.detect(std.fs.File.stderr());
    defer std.debug.unlockStderrWriter();
    ttyconf.setColor(stderr, switch (message_level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    ttyconf.setColor(stderr, .bold) catch {};
    stderr.writeAll(message_level.asText()) catch return;
    ttyconf.setColor(stderr, .reset) catch {};
    ttyconf.setColor(stderr, .dim) catch {};
    ttyconf.setColor(stderr, .bold) catch {};
    if (scope != .default) {
        stderr.print("({s})", .{@tagName(scope)}) catch return;
    }
    stderr.writeAll(": ") catch return;
    ttyconf.setColor(stderr, .reset) catch {};
    stderr.print(format ++ "\n", args) catch return;
}

pub const std_options = std.Options{
    .logFn = log,
};

pub fn main() !void {
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, std.posix.SIG.INT);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);

    const efd = try std.posix.eventfd(0, std.os.linux.EFD.NONBLOCK);

    var server_queue = try SpscQueue(common.GameMessage, true).initCapacity(std.heap.page_allocator, 64);
    defer server_queue.deinit();

    var game_queue = try SpscQueue(common.ServerMessage, true).initCapacity(std.heap.page_allocator, 64);
    defer game_queue.deinit();

    const server_thread = try std.Thread.spawn(.{}, server.main, .{ efd, &server_queue, &game_queue });
    const game_thread = try std.Thread.spawn(.{}, game.main, .{ efd, &game_queue, &server_queue });

    server_thread.join();
    game_thread.join();
}
