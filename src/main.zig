const std = @import("std");

const common = @import("common/mod.zig");
const packet = @import("packet/mod.zig");

const PORT = 25565;
const ADDRESS = "127.0.0.1";

const URING_QUEUE_ENTRIES = 4096;

fn processPacket(client: *common.client.Client) void {
    var offset: usize = 0;

    const len = packet.types.VarInt.decode(&client.read_buf) orelse return;
    offset += len.len;

    if (client.read_buf_tail - offset > len.value) {
        return;
    }

    const id = packet.types.VarInt.decode(client.read_buf[offset..]) orelse return;
    offset += id.len;

    std.debug.print("packet id: {d}\n", .{id.value});

    const total_len = @as(usize, @intCast(len.value)) + len.len;
    @memmove(client.read_buf[0..(client.read_buf_tail - total_len)], client.read_buf[total_len..client.read_buf_tail]);
    client.read_buf_tail -= total_len;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var client_manager = try common.client.ClientManager.init(8, gpa.allocator(), gpa.allocator());
    defer client_manager.deinit();

    const serverfd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(serverfd);

    const addr_in = try std.net.Address.parseIp4(ADDRESS, PORT);

    try std.posix.setsockopt(serverfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(serverfd, &addr_in.any, addr_in.getOsSockLen());
    try std.posix.listen(serverfd, 128);

    std.log.info("server listening on port {d}.", .{PORT});

    var ring = try common.uring.Ring.init(URING_QUEUE_ENTRIES);
    defer ring.deinit();

    std.log.info("ring initialized: {d}.", .{ring.fd});

    const ctx = common.Context{
        .client_manager = client_manager,
        .ring = ring,
        .server_fd = serverfd,
    };
    _ = ctx;

    var addr: std.os.linux.sockaddr = undefined;
    var addr_len: std.os.linux.socklen_t = @sizeOf(@TypeOf(addr));

    {
        const sqe = try ring.getSqe();
        sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.Accept, .d = 0, .fd = 0 });
        sqe.prep_accept(serverfd, &addr, &addr_len, 0);
    }

    _ = try ring.submit();
    std.debug.print("submitted to SQE\n", .{});

    while (true) {
        const cqe = try ring.waitCqe();
        const ud: common.uring.Userdata = @bitCast(cqe.user_data);
        switch (ud.op) {
            .Accept => {
                const cfd = cqe.res;
                std.debug.print("new client: {d}\n", .{cfd});

                var client = try client_manager.add(cfd);
                client.state = .Handshake;
                client.addr = addr;

                {
                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.ACCEPT;
                    sqe.prep_accept(serverfd, &addr, &addr_len, 0);
                    sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.Accept, .d = 0, .fd = cfd });
                }

                {
                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.READ;
                    sqe.prep_read(cfd, &client_manager.get(cfd).?.read_buf, 0);
                    sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.Read, .d = 0, .fd = cfd });
                }

                _ = try ring.submit();
            },
            .Read => {
                const cfd = ud.fd;
                const bytes: usize = @intCast(cqe.res);

                if (0 == bytes) {
                    client_manager.remove(cfd);
                    std.debug.print("closed client: {d}\n", .{cfd});
                    continue;
                }

                const client = client_manager.get(cfd).?;
                client.read_buf_tail += bytes;

                std.debug.print("read {d} bytes from client {d}: {any}\n", .{ bytes, cfd, client_manager.get(cfd).?.read_buf[0..client.read_buf_tail] });

                processPacket(client);

                const sqe = try ring.getSqe();
                sqe.opcode = std.os.linux.IORING_OP.READ;
                sqe.prep_read(cfd, client.read_buf[client.read_buf_tail..], 0);
                sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.Read, .d = 0, .fd = cfd });

                _ = try ring.submit();
            },
        }
    }
}
