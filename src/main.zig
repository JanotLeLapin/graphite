const std = @import("std");

const common = @import("common/mod.zig");
const packet = @import("packet/mod.zig");

const PORT = 25565;
const ADDRESS = "127.0.0.1";

const URING_QUEUE_ENTRIES = 4096;

pub const Modules = .{
    @import("module/vanilla.zig").VanillaModule(.{
        .send_join_message = true,
        .send_quit_message = true,
    }),
    @import("module/pachelbel.zig").PachelbelModule,
};

fn dispatch(
    ctx: *common.Context,
    comptime method_name: []const u8,
    args: anytype,
) void {
    inline for (Modules) |ModuleType| {
        const instance = ctx.module_registry.get(ModuleType);

        if (@hasDecl(ModuleType, method_name)) {
            const method = @field(ModuleType, method_name);
            const call_args = .{ instance, ctx } ++ args;
            const result = @call(.auto, method, call_args);

            const ReturnType = @typeInfo(@TypeOf(result));
            if (ReturnType == .error_union) {
                result catch |e| {
                    std.log.err(
                        "module {s}: {s}: {s}",
                        .{
                            @typeName(ModuleType),
                            method_name,
                            @errorName(e),
                        },
                    );
                };
            }
        }
    }
}

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
    ctx: *common.Context,
    client: *common.client.Client,
    p: packet.ServerBoundPacket,
) !void {
    switch (p) {
        .handshake => client.state = @enumFromInt(p.handshake.next_state),
        .status_request => {
            dispatch(ctx, "onStatus", .{client});
        },
        .status_ping => {
            const b = try ctx.buffer_pool.allocBuf();
            {
                errdefer ctx.buffer_pool.releaseBuf(b.idx);

                b.data[0] = 9;
                b.data[1] = 0x01;
                @memcpy(b.data[2..10], @as([]const u8, @ptrCast(&p.status_ping.payload)));

                try b.prepareOneshot(ctx.ring, client.fd, 10);
            }
            _ = try ctx.ring.submit();
        },
        .login_start => {
            client.username = std.ArrayListUnmanaged(u8).initBuffer(&client.username_buf);
            client.username.appendSliceBounded(p.login_start.username[0..@min(p.login_start.username.len, client.username_buf.len - 1)]) catch unreachable;

            var uuid_buf: [36]u8 = undefined;
            client.uuid = common.Uuid.random(std.crypto.random);
            client.uuid.stringify(&uuid_buf);

            std.log.debug("client: {d}, username: '{s}'", .{ client.fd, client.username.items });

            const b = try ctx.buffer_pool.allocBuf();
            errdefer ctx.buffer_pool.releaseBuf(b.idx);

            var offset: usize = 0;

            offset += packet.ClientLoginSuccess.encode(&.{
                .uuid = &uuid_buf,
                .username = client.username.items,
            }, b.data[offset..]) orelse return PacketProcessingError.EncodingFailure;

            offset += packet.ClientPlayJoinGame.encode(&.{
                .eid = 0,
                .gamemode = .survival,
                .dimension = .overworld,
                .difficulty = .normal,
                .max_players = 20,
                .level_type = "default",
                .reduced_debug_info = 0,
            }, b.data[offset..]) orelse return PacketProcessingError.EncodingFailure;

            offset += packet.ClientPlayPlayerPositionAndLook.encode(&.{
                .x = 0.0,
                .y = 67.0,
                .z = 0.0,
                .yaw = 0.0,
                .pitch = 0.0,
                .flags = 0,
            }, b.data[offset..]) orelse return PacketProcessingError.EncodingFailure;

            try b.prepareOneshot(ctx.ring, client.fd, offset);
            client.state = .play;

            dispatch(ctx, "onJoin", .{client});
        },
        .play_chat_message => |pd| {
            dispatch(ctx, "onChatMessage", .{ client, pd.message });
        },
        else => {},
    }
}

fn splitPackets(ctx: *common.Context, client: *common.client.Client) void {
    var global_offset: usize = 0;
    while (true) {
        var offset = global_offset;

        const len = packet.types.VarInt.decode(client.read_buf[offset..client.read_buf_tail]) orelse break;
        offset += len.len;

        if (client.read_buf_tail - offset < len.value) {
            break;
        }

        const packet_end = offset + @as(usize, @intCast(len.value));

        const id = packet.types.VarInt.decode(client.read_buf[offset..packet_end]) orelse break;
        offset += id.len;

        if (packet.ServerBoundPacket.decode(client.state, id.value, client.read_buf[offset..packet_end])) |p| {
            processPacket(ctx, client, p) catch |e| {
                std.log.debug("client: {d}, failed to process packet with id {x}: {s}", .{ client.fd, id.value, @errorName(e) });
            };
        }

        global_offset = packet_end;
    }

    @memmove(client.read_buf[0..(client.read_buf_tail - global_offset)], client.read_buf[global_offset..client.read_buf_tail]);
    client.read_buf_tail = client.read_buf_tail - global_offset;
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
    timerspec.it_interval.nsec = 50000000;
    timerspec.it_value.nsec = 1;

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

fn keepaliveTask(ctx: *common.Context, _: u64) void {
    ctx.scheduler.schedule(&keepaliveTask, 200, 0) catch {};

    const b = ctx.buffer_pool.allocBuf() catch return;

    const size = packet.ClientPlayKeepAlive.encode(
        &.{ .id = packet.types.VarInt{ .value = 67 } },
        &b.data,
    ).?;

    b.prepareBroadcast(ctx.ring, ctx.client_manager.lookup.items, size) catch {
        ctx.buffer_pool.releaseBuf(b.idx);
        return;
    };
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

    var buffer_pool = try common.buffer.BufferPool(4096).init(gpa.allocator(), 64);
    defer buffer_pool.deinit();

    var scheduler = common.scheduler.Scheduler.init(gpa.allocator());
    defer scheduler.deinit();

    try scheduler.schedule(&keepaliveTask, 200, 0);

    var module_registry = try common.ModuleRegistry.init(gpa.allocator());
    defer module_registry.deinit();

    var ctx = common.Context{
        .client_manager = &client_manager,
        .ring = &ring,
        .buffer_pool = &buffer_pool,
        .scheduler = &scheduler,
        .module_registry = module_registry,
    };

    {
        const sqe = try ring.getSqe();
        sqe.prep_accept(server_fd, &addr, &addr_len, 0);
        sqe.user_data = @bitCast(common.uring.Userdata{ .op = .accept, .d = 0, .fd = 0 });
    }

    {
        const sqe = try ring.getSqe();
        sqe.prep_read(sig_fd, @ptrCast(&siginfo), 0);
        sqe.user_data = @bitCast(common.uring.Userdata{ .op = .sigint, .d = 0, .fd = 0 });
    }

    {
        const sqe = try ring.getSqe();
        sqe.prep_read(timer_fd, @ptrCast(&tinfo), 0);
        sqe.user_data = @bitCast(common.uring.Userdata{ .op = .timer, .d = 0, .fd = 0 });
    }

    _ = try ring.submit();

    while (true) {
        const cqe = try ring.waitCqe();

        const ud: common.uring.Userdata = @bitCast(cqe.user_data);
        switch (ud.op) {
            .accept => {
                if (cqe.res < 0) {
                    const errcode: usize = @intCast(-cqe.res);
                    const err = std.posix.errno(errcode);
                    std.log.err("cqe error: accept: {s}", .{@tagName(err)});
                } else {
                    const cfd = cqe.res;
                    std.log.debug("client: {d} connected", .{cfd});

                    var client = try client_manager.add(cfd);
                    client.state = .handshake;
                    client.addr = addr;

                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.READ;
                    sqe.prep_read(cfd, &client_manager.get(cfd).?.read_buf, 0);
                    sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.read, .d = 0, .fd = cfd });
                }

                const sqe = try ring.getSqe();
                sqe.opcode = std.os.linux.IORING_OP.ACCEPT;
                sqe.prep_accept(server_fd, &addr, &addr_len, 0);
                sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.accept, .d = 0, .fd = 0 });

                _ = try ctx.ring.submit();
            },
            .sigint => {
                std.log.info("caught sigint", .{});
                break;
            },
            .timer => {
                const sqe = try ctx.ring.getSqe();
                sqe.prep_read(timer_fd, @ptrCast(&tinfo), 0);
                sqe.user_data = @bitCast(common.uring.Userdata{ .op = .timer, .d = 0, .fd = 0 });

                scheduler.tick(&ctx);
                _ = try ctx.ring.submit();
            },
            .read => {
                const cfd = ud.fd;
                if (cqe.res < 0) {
                    const errcode: usize = @intCast(-cqe.res);
                    const err = std.posix.errno(errcode);
                    std.log.err("cqe error: read: {s}", .{@tagName(err)});
                    client_manager.remove(cfd);
                    continue;
                }

                const client = client_manager.get(cfd).?;
                const bytes: usize = @intCast(cqe.res);
                if (0 == bytes) {
                    if (client.state == .play) {
                        dispatch(&ctx, "onQuit", .{client});
                    }
                    client_manager.remove(cfd);
                    std.log.debug("client: {d} disconnected", .{cfd});
                    continue;
                }

                client.read_buf_tail += bytes;

                splitPackets(&ctx, client);

                const sqe = try ring.getSqe();
                sqe.opcode = std.os.linux.IORING_OP.READ;
                sqe.prep_read(cfd, client.read_buf[client.read_buf_tail..], 0);
                sqe.user_data = @bitCast(common.uring.Userdata{ .op = common.uring.UserdataOp.read, .d = 0, .fd = cfd });

                _ = try ctx.ring.submit();
            },
            .write => {
                const cfd = ud.fd;
                if (cqe.res < 0) {
                    const errcode: usize = @intCast(-cqe.res);
                    const err = std.posix.errno(errcode);
                    std.log.err("cqe error: write: {s}", .{@tagName(err)});
                    client_manager.remove(cfd);
                    continue;
                }

                const b = ctx.buffer_pool.buffers[@intCast(ud.d)];
                b.ref_count -= 1;
                if (0 == b.ref_count) {
                    ctx.buffer_pool.releaseBuf(@intCast(ud.d));
                }
            },
        }
    }
}
