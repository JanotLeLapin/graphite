const std = @import("std");
const graphite = @import("graphite");

const c = @cImport({
    @cInclude("liburing.h");
});

const PORT = 25565;
const ADDRESS = "127.0.0.1";

pub fn main() !void {
    const serverfd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(serverfd);

    const addr_in = try std.net.Address.parseIp4("127.0.0.1", 25565);

    try std.posix.setsockopt(serverfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(serverfd, &addr_in.any, addr_in.getOsSockLen());
    try std.posix.listen(serverfd, 128);

    std.log.info("server listening on port {d}.", .{PORT});
}
