const std = @import("std");
const graphite = @import("graphite");

const c = @cImport({
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("arpa/inet.h");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
    @cInclude("errno.h");
    @cInclude("liburing.h");
});

const PORT = 25565;
const ADDRESS = "127.0.0.1";

const CError = error{
    Err,
};

fn ctry(msg: [*:0]const u8, res: c_int) !c_int {
    if (0 > res) {
        const errno = c.__errno_location().*;
        std.log.err("{s}: {s}", .{ msg, c.strerror(errno) });
        return CError.Err;
    }
    return res;
}

pub fn main() !void {
    const serverfd = try ctry("socket", c.socket(c.AF_INET, c.SOCK_STREAM, 0));
    defer _ = c.close(serverfd);

    var sockaddr_in = c.sockaddr_in{
        .sin_family = c.AF_INET,
        .sin_port = c.htons(PORT),
    };
    _ = c.inet_pton(c.AF_INET, ADDRESS, &sockaddr_in.sin_addr);

    _ = try ctry("bind", c.bind(serverfd, @ptrCast(&sockaddr_in), @sizeOf(@TypeOf(sockaddr_in))));
    _ = try ctry("listen", c.listen(serverfd, c.SOMAXCONN));

    std.log.info("server listening on port: {d}", .{PORT});
}
