const std = @import("std");

const common = @import("common/mod.zig");
const packet = @import("packet/mod.zig");

const PORT = 25565;
const ADDRESS = "127.0.0.1";

const URING_QUEUE_ENTRIES = 4096;

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

fn processPacket(
    ctx: common.Context,
    client: *common.client.Client,
    packet_id: i32,
    packet_buf: []const u8,
) !void {
    switch (client.state) {
        .Handshake => if (packet.ServerHandshake.decode(packet_buf)) |p| {
            std.debug.print("got handshake: {d}, '{s}:{d}'.\n", .{ p.protocol_version.value, p.server_address, p.server_port });
            client.state = @enumFromInt(p.next_state);
        },
        .Status => {
            switch (packet_id) {
                0x00 => if (ctx.buffer_pool.allocBuf()) |b| {
                    if (packet.ClientStatusResponse.encode(
                        &.{ .response = "{\"version\":{\"name\":\"1.8.8\",\"protocol\":47},\"players\":{\"max\":20,\"online\":0,\"sample\":[]},\"description\":{\"text\":\"This is a really really long description\",\"color\":\"red\"}}" },
                        &b.data,
                    )) |size| {
                        try b.prepareOneshot(ctx.ring, client.fd, size);
                        _ = try ctx.ring.submit();
                    } else {
                        ctx.buffer_pool.releaseBuf(b.idx);
                    }
                },
                0x01 => if (ctx.buffer_pool.allocBuf()) |b| {
                    @memcpy(b.data[0..10], client.read_buf[0..10]);
                    try b.prepareOneshot(ctx.ring, client.fd, 10);
                    _ = try ctx.ring.submit();
                },
                else => {},
            }
        },
        .Login => {},
    }
}

fn splitPackets(ctx: common.Context, client: *common.client.Client) !void {
    while (true) {
        if (client.read_buf_tail == 0) {
            break;
        }

        var offset: usize = 0;

        const len = packet.types.VarInt.decode(&client.read_buf) orelse break;
        offset += len.len;

        if (client.read_buf_tail - offset > len.value) {
            break;
        }

        const id = packet.types.VarInt.decode(client.read_buf[offset..]) orelse break;
        offset += id.len;

        std.debug.print("packet id: {d}\n", .{id.value});
        try processPacket(ctx, client, id.value, client.read_buf[offset..]);

        const total_len = @as(usize, @intCast(len.value)) + len.len;
        @memmove(client.read_buf[0..(client.read_buf_tail - total_len)], client.read_buf[total_len..client.read_buf_tail]);
        client.read_buf_tail -= total_len;
    }
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

    var buffer_pool = try common.buffer.BufferPool(4096, 64).init(gpa.allocator());

    const ctx = common.Context{
        .client_manager = client_manager,
        .ring = &ring,
        .server_fd = serverfd,
        .buffer_pool = &buffer_pool,
    };

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

                try splitPackets(ctx, client);

                const sqe = try ring.getSqe();
                sqe.opcode = std.os.linux.IORING_OP.READ;
                sqe.prep_read(cfd, client.read_buf[client.read_buf_tail..], 0);
                sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.Read, .d = 0, .fd = cfd });

                _ = try ring.submit();
            },
            .Write => {
                const b = &ctx.buffer_pool.buffers[@intCast(ud.d)];

                switch (b.t) {
                    .Oneshot => {
                        ctx.buffer_pool.releaseBuf(@intCast(ud.d));
                    },
                    else => {},
                }
            },
        }
    }
}
