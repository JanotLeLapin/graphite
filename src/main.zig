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

const PacketProcessingError = error{
    EncodingFailure,
};

fn processPacket(
    ctx: common.Context,
    client: *common.client.Client,
    p: packet.ServerBoundPacket,
) !void {
    switch (p) {
        .Handshake => client.state = @enumFromInt(p.Handshake.next_state),
        .StatusRequest => if (ctx.buffer_pool.allocBuf()) |b| {
            {
                errdefer ctx.buffer_pool.releaseBuf(b.idx);

                const size = packet.ClientStatusResponse.encode(
                    &.{ .response = "{\"version\":{\"name\":\"1.8.8\",\"protocol\":47},\"players\":{\"max\":20,\"online\":0,\"sample\":[]},\"description\":{\"text\":\"This is a really really long description\",\"color\":\"red\"}}" },
                    &b.data,
                ) orelse return PacketProcessingError.EncodingFailure;

                try b.prepareOneshot(ctx.ring, client.fd, size);
            }
            _ = try ctx.ring.submit();
        },
        .StatusPing => if (ctx.buffer_pool.allocBuf()) |b| {
            {
                errdefer ctx.buffer_pool.releaseBuf(b.idx);

                b.data[0] = 9;
                b.data[1] = 0x01;
                @memcpy(b.data[2..10], @as([]const u8, @ptrCast(&p.StatusPing.payload)));

                try b.prepareOneshot(ctx.ring, client.fd, 10);
            }
            _ = try ctx.ring.submit();
        },
        .LoginStart => {
            client.username = std.ArrayListUnmanaged(u8).initBuffer(&client.username_buf);
            client.username.appendSliceBounded(p.LoginStart.username[0..@min(p.LoginStart.username.len, client.username_buf.len - 1)]) catch unreachable;

            var uuid_buf: [36]u8 = undefined;
            client.uuid = common.Uuid.random(std.crypto.random);
            client.uuid.stringify(&uuid_buf);

            std.log.debug("client: {d}, username: '{s}'", .{ client.fd, client.username.items });

            if (ctx.buffer_pool.allocBuf()) |b| {
                errdefer ctx.buffer_pool.releaseBuf(b.idx);

                const size = packet.ClientLoginSuccess.encode(&.{
                    .uuid = &uuid_buf,
                    .username = client.username.items,
                }, &b.data) orelse return PacketProcessingError.EncodingFailure;

                try b.prepareOneshot(ctx.ring, client.fd, size);
                _ = try ctx.ring.submit();

                client.state = .Play;
            } else {
                return;
            }

            if (ctx.buffer_pool.allocBuf()) |b| {
                {
                    errdefer ctx.buffer_pool.releaseBuf(b.idx);

                    const size = packet.ClientPlayJoinGame.encode(&.{
                        .eid = 0,
                        .gamemode = .Survival,
                        .dimension = .Overworld,
                        .difficulty = .Normal,
                        .max_players = 20,
                        .level_type = "default",
                        .reduced_debug_info = 0,
                    }, &b.data) orelse return PacketProcessingError.EncodingFailure;

                    try b.prepareOneshot(ctx.ring, client.fd, size);
                    _ = try ctx.ring.submit();
                }
            } else {
                return;
            }

            if (ctx.buffer_pool.allocBuf()) |b| {
                {
                    errdefer ctx.buffer_pool.releaseBuf(b.idx);

                    const size = packet.ClientPlayPlayerPositionAndLook.encode(&.{
                        .x = 0.0,
                        .y = 67.0,
                        .z = 0.0,
                        .yaw = 0.0,
                        .pitch = 0.0,
                        .flags = 0,
                    }, &b.data) orelse return PacketProcessingError.EncodingFailure;

                    try b.prepareOneshot(ctx.ring, client.fd, size);
                    _ = try ctx.ring.submit();
                }
            }
        },
    }
}

fn splitPackets(ctx: common.Context, client: *common.client.Client) void {
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

        if (packet.ServerBoundPacket.decode(client.state, id.value, client.read_buf[offset..])) |p| {
            processPacket(ctx, client, p) catch |e| {
                std.log.debug("client: {d}, failed to process packet with id {x}: {s}", .{ client.fd, id.value, @errorName(e) });
            };
        } else {
            std.log.debug("client: {d}, unknown packet with id: {x}", .{ client.fd, id.value });
        }

        const total_len = @as(usize, @intCast(len.value)) + len.len;
        @memmove(client.read_buf[0..(client.read_buf_tail - total_len)], client.read_buf[total_len..client.read_buf_tail]);
        client.read_buf_tail -= total_len;
    }
}

fn createSig() !i32 {
    var sigmask = std.posix.sigemptyset();
    std.posix.sigaddset(&sigmask, std.posix.SIG.INT);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &sigmask, null);

    const sigfd = try std.posix.signalfd(-1, &sigmask, 0);
    return sigfd;
}

fn createTimer() !i32 {
    var timerspec = std.mem.zeroes(std.os.linux.itimerspec);
    timerspec.it_interval.sec = 10;
    timerspec.it_value.sec = 5;

    const timer_fd = try std.posix.timerfd_create(std.posix.timerfd_clockid_t.MONOTONIC, std.os.linux.TFD{});
    try std.posix.timerfd_settime(timer_fd, std.os.linux.TFD.TIMER{}, &timerspec, null);
    return timer_fd;
}

fn createServer() !i32 {
    const server_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);

    const addr_in = try std.net.Address.parseIp4(ADDRESS, PORT);
    try std.posix.setsockopt(
        server_fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
    try std.posix.bind(server_fd, &addr_in.any, addr_in.getOsSockLen());
    try std.posix.listen(server_fd, 128);

    return server_fd;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var client_manager = try common.client.ClientManager.init(8, gpa.allocator(), gpa.allocator());
    defer client_manager.deinit();

    const sig_fd = try createSig();
    defer std.posix.close(sig_fd);
    var siginfo: std.posix.siginfo_t = undefined;

    const timer_fd = try createTimer();
    defer std.posix.close(timer_fd);
    var tinfo: u64 = 0;

    const server_fd = try createServer();
    defer std.posix.close(server_fd);
    var addr: std.os.linux.sockaddr = undefined;
    var addr_len: std.os.linux.socklen_t = @sizeOf(@TypeOf(addr));

    std.log.info("server listening on port {d}.", .{PORT});

    var ring = try common.uring.Ring.init(URING_QUEUE_ENTRIES);
    defer ring.deinit();

    var buffer_pool = try common.buffer.BufferPool(4096, 64).init(gpa.allocator());
    defer buffer_pool.deinit();

    const ctx = common.Context{
        .client_manager = client_manager,
        .ring = &ring,
        .buffer_pool = &buffer_pool,
    };

    {
        const sqe = try ring.getSqe();
        sqe.prep_accept(server_fd, &addr, &addr_len, 0);
        sqe.user_data = @bitCast(common.uring.Userdata{ .op = .Accept, .d = 0, .fd = 0 });
    }

    {
        const sqe = try ring.getSqe();
        sqe.prep_read(sig_fd, @ptrCast(&siginfo), 0);
        sqe.user_data = @bitCast(common.uring.Userdata{ .op = .Sigint, .d = 0, .fd = 0 });
    }

    {
        const sqe = try ring.getSqe();
        sqe.prep_read(timer_fd, @ptrCast(&tinfo), 0);
        sqe.user_data = @bitCast(common.uring.Userdata{ .op = .Timer, .d = 0, .fd = 0 });
    }

    _ = try ring.submit();

    while (true) {
        const cqe = try ring.waitCqe();
        const ud: common.uring.Userdata = @bitCast(cqe.user_data);
        switch (ud.op) {
            .Accept => {
                const cfd = cqe.res;
                std.log.debug("client: {d} connected", .{cfd});

                var client = try client_manager.add(cfd);
                client.state = .Handshake;
                client.addr = addr;

                {
                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.ACCEPT;
                    sqe.prep_accept(server_fd, &addr, &addr_len, 0);
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
            .Sigint => {
                std.log.info("caught sigint", .{});
                break;
            },
            .Timer => {
                std.log.debug("keepalive", .{});

                const sqe = try ring.getSqe();
                sqe.prep_read(timer_fd, @ptrCast(&tinfo), 0);
                sqe.user_data = @bitCast(common.uring.Userdata{ .op = .Timer, .d = 0, .fd = 0 });
                _ = try ring.submit();
            },
            .Read => {
                const cfd = ud.fd;
                if (cqe.res < 0) {
                    std.log.err("cqe error: {d}", .{cqe.res});
                    continue;
                }

                const bytes: usize = @intCast(cqe.res);

                if (0 == bytes) {
                    client_manager.remove(cfd);
                    std.log.debug("client: {d} disconnected", .{cfd});
                    continue;
                }

                const client = client_manager.get(cfd).?;
                client.read_buf_tail += bytes;

                std.log.debug("client: {d}, read {d} bytes: {any}", .{
                    cfd,
                    bytes,
                    client_manager.get(cfd).?.read_buf[client.read_buf_tail - bytes .. client.read_buf_tail],
                });

                splitPackets(ctx, client);

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
