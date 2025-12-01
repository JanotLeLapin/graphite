const std = @import("std");

const graphite = @import("graphite");
const uring = @import("uring.zig");

const PORT = 25565;
const ADDRESS = "127.0.0.1";

const URING_QUEUE_ENTRIES = 4096;

const UserdataOp = enum(u16) {
    Accept,
    Read,
};

const Userdata = packed struct {
    op: UserdataOp,
    d: u16,
    fd: i32,
};

const Client = struct {
    read_buf: [4096]u8,
    write_buf: [4096]u8,
    addr: std.os.linux.sockaddr,
};

pub fn main() !void {
    var clients = std.mem.zeroes([512]Client);

    const serverfd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(serverfd);

    const addr_in = try std.net.Address.parseIp4("127.0.0.1", 25565);

    try std.posix.setsockopt(serverfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(serverfd, &addr_in.any, addr_in.getOsSockLen());
    try std.posix.listen(serverfd, 128);

    std.log.info("server listening on port {d}.", .{PORT});

    var ring = try uring.Ring.init(URING_QUEUE_ENTRIES);
    defer ring.deinit();

    std.log.info("ring initialized: {d}.", .{ring.fd});

    var addr: std.os.linux.sockaddr = undefined;
    var addr_len: std.os.linux.socklen_t = @sizeOf(@TypeOf(addr));

    {
        const sqe = try ring.getSqe();
        sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Accept, .d = 0, .fd = 0 });
        sqe.prep_accept(serverfd, &addr, &addr_len, 0);
    }

    _ = try ring.submit();
    std.debug.print("submitted to SQE\n", .{});

    while (true) {
        const cqe = try ring.waitCqe();
        const ud: Userdata = @bitCast(cqe.user_data);
        switch (ud.op) {
            .Accept => {
                const cfd = cqe.res;
                std.debug.print("new client: {d}\n", .{cfd});

                clients[@intCast(cfd)] = Client{
                    .read_buf = undefined,
                    .write_buf = undefined,
                    .addr = addr,
                };

                {
                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.ACCEPT;
                    sqe.prep_accept(serverfd, &addr, &addr_len, 0);
                    sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Accept, .d = 0, .fd = cfd });
                }

                {
                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.READ;
                    sqe.prep_read(cfd, &clients[@intCast(cfd)].read_buf, 0);
                    sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Read, .d = 0, .fd = cfd });
                }

                _ = try ring.submit();
            },
            .Read => {
                const cfd = ud.fd;
                const bytes: usize = @intCast(cqe.res);

                if (0 == bytes) {
                    clients[@intCast(cfd)] = std.mem.zeroes(Client);
                    std.debug.print("closed client: {d}\n", .{cfd});
                    continue;
                }

                std.debug.print("read {d} bytes from client {d}: {any}\n", .{ bytes, cfd, clients[@intCast(cfd)].read_buf[0..bytes] });

                const sqe = try ring.getSqe();
                sqe.opcode = std.os.linux.IORING_OP.READ;
                sqe.prep_read(cfd, &clients[@intCast(cfd)].read_buf, 0);
                sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Read, .d = 0, .fd = cfd });

                _ = try ring.submit();
            },
        }
    }
}
