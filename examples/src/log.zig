const std = @import("std");

const common = @import("graphite-common");
const Client = common.client.Client;
const Context = common.Context;

pub fn formatAddr(buf: []u8, addr: *const std.posix.sockaddr) ![]u8 {
    if (addr.family != std.posix.AF.INET) {
        return error.NotIPV4;
    }

    return try std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        addr.data[2],
        addr.data[3],
        addr.data[4],
        addr.data[5],
    });
}

pub const LogModuleOptions = struct {
    show_name: bool = true,
    show_ip: bool = true,
};

fn info(
    comptime prefix: []const u8,
    comptime fmt: []const u8,
    comptime opt: LogModuleOptions,
    client: *common.client.Client,
    args: anytype,
) !void {
    var ip_buf: [16]u8 = undefined;

    const fixed_prefix = prefix ++ (":" ++ (comptime if (opt.show_ip) " {s}" else "") ++ (comptime if (opt.show_name) " {s}" else ""));
    const fixed_args = ((if (opt.show_ip) .{
        try formatAddr(&ip_buf, &client.addr),
    } else .{}) ++ (if (opt.show_name) .{
        client.username.items,
    } else .{})) ++ args;

    std.log.info(fixed_prefix ++ fmt, fixed_args);
}

pub fn LogModule(comptime opt: LogModuleOptions) type {
    return struct {
        _: u8 = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return @This(){};
        }
        pub fn deinit(_: *@This()) void {}

        pub fn onJoin(client: *common.client.Client) !void {
            try info("join", "", opt, client, .{});
        }

        pub fn onQuit(client: *Client) !void {
            try info("quit", "", opt, client, .{});
        }

        pub fn onChatMessage(client: *Client, msg: []const u8) !void {
            try info("chat", ": {s}", opt, client, .{msg});
        }
    };
}
