const std = @import("std");

const common = @import("graphite-common");
const protocol = @import("graphite-protocol");

const PORT = 25565;
const ADDRESS = "127.0.0.1";

const URING_QUEUE_ENTRIES = 4096;

pub const Modules = .{
    @import("module/vanilla.zig").VanillaModule(.{
        .send_join_message = true,
        .send_quit_message = true,
    }),
    @import("module/log.zig").LogModule(.{}),
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
    p: protocol.ServerBoundPacket,
) !void {
    switch (p) {
        .handshake => client.state = @enumFromInt(p.handshake.next_state),
        .status_request => {
            dispatch(ctx, "onStatus", .{client});
        },
        .status_ping => {
            const b = try ctx.buffer_pools.allocBuf(.@"6");
            {
                errdefer ctx.buffer_pools.releaseBuf(b.idx);

                b.ptr[0] = 9;
                b.ptr[1] = 0x01;
                @memcpy(b.ptr[2..10], @as([]const u8, @ptrCast(&p.status_ping.payload)));

                try ctx.ring.prepareOneshot(client.fd, b, 10);
            }
        },
        .login_start => {
            client.username = std.ArrayListUnmanaged(u8).initBuffer(&client.username_buf);
            client.username.appendSliceBounded(p.login_start.username[0..@min(p.login_start.username.len, client.username_buf.len - 1)]) catch unreachable;

            var uuid_buf: [36]u8 = undefined;
            client.uuid = common.Uuid.random(std.crypto.random);
            client.uuid.stringify(&uuid_buf);

            std.log.debug("client: {d}, username: '{s}'", .{ client.fd, client.username.items });

            const b = try ctx.buffer_pools.allocBuf(.@"10");
            errdefer ctx.buffer_pools.releaseBuf(b.idx);

            var offset: usize = 0;

            offset += try protocol.ClientLoginSuccess.encode(&.{
                .uuid = &uuid_buf,
                .username = client.username.items,
            }, b.ptr[offset..]);

            offset += try protocol.ClientPlayJoinGame.encode(&.{
                .entity_id = 0,
                .gamemode = protocol.Gamemode(.survival, false),
                .dimension = .overworld,
                .difficulty = .normal,
                .max_players = 20,
                .level_type = "default",
                .reduced_debug_info = false,
            }, b.ptr[offset..]);

            offset += try protocol.ClientPlayPlayerPositionAndLook.encode(&.{
                .x = 0.0,
                .y = 67.0,
                .z = 0.0,
                .yaw = 0.0,
                .pitch = 0.0,
                .flags = 0,
            }, b.ptr[offset..]);

            try ctx.ring.prepareOneshot(client.fd, b, offset);
            client.state = .play;

            var cb = try common.zcs.CmdBuf.init(.{
                .name = null,
                .gpa = ctx.zcs_alloc,
                .es = ctx.entities,
            });
            defer cb.deinit(ctx.zcs_alloc, ctx.entities);

            _ = client.e.add(&cb, common.ecs.Location, .{ .x = 0.0, .y = 67.0, .z = 0.0, .on_ground = false });

            common.zcs.CmdBuf.Exec.immediate(ctx.entities, &cb);

            dispatch(ctx, "onJoin", .{client});
        },
        .play_chat_message => |pd| {
            dispatch(ctx, "onChatMessage", .{ client, pd.message });
        },
        .play_player_position => |pd| {
            const l = client.e.get(ctx.entities, common.ecs.Location).?;
            l.x = pd.x;
            l.y = pd.y;
            l.z = pd.z;
            l.on_ground = pd.on_ground;

            dispatch(ctx, "onMove", .{client});
        },
        .play_player_position_and_look => |pd| {
            const l = client.e.get(ctx.entities, common.ecs.Location).?;
            l.x = pd.x;
            l.y = pd.y;
            l.z = pd.z;
            l.on_ground = pd.on_ground;

            dispatch(ctx, "onMove", .{client});
        },
        else => {},
    }
}

fn splitPackets(ctx: *common.Context, client: *common.client.Client) void {
    var global_offset: usize = 0;
    while (true) {
        var offset = global_offset;

        const len = protocol.types.VarInt.decode(client.read_buf[offset..client.read_buf_tail]) catch break;
        offset += len.len;

        if (client.read_buf_tail - offset < len.value) {
            break;
        }

        const packet_end = offset + @as(usize, @intCast(len.value));

        const id = protocol.types.VarInt.decode(client.read_buf[offset..packet_end]) catch break;
        offset += id.len;

        const p = protocol.ServerBoundPacket.decode(client.state, id.value, client.read_buf[offset..packet_end]) catch {
            global_offset = packet_end;
            continue;
        };

        processPacket(ctx, client, p) catch |e| {
            std.log.debug("client: {d}, failed to process packet with id {x}: {s}", .{ client.fd, id.value, @errorName(e) });
        };

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

    const b = ctx.buffer_pools.allocBuf(.@"6") catch return;

    const size = protocol.ClientPlayKeepAlive.encode(
        &.{ .id = protocol.types.VarInt{ .value = 67 } },
        b.ptr,
    ) catch return;

    ctx.ring.prepareBroadcast(ctx, b, size) catch {
        ctx.buffer_pools.releaseBuf(b.idx);
        return;
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const zcs_alloc = gpa.allocator();
    var entities = try common.zcs.Entities.init(.{
        .gpa = zcs_alloc,
    });
    defer entities.deinit(zcs_alloc);

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

    var ring = try common.uring.Ring.init(gpa.allocator(), URING_QUEUE_ENTRIES);
    defer ring.deinit();

    var buffer_pools = try common.buffer.BufferPools.init(gpa.allocator());
    defer buffer_pools.deinit();

    var scheduler = common.scheduler.Scheduler.init(gpa.allocator());
    defer scheduler.deinit();

    try scheduler.schedule(&keepaliveTask, 200, 0);

    var module_registry = try common.ModuleRegistry.init(gpa.allocator());
    defer module_registry.deinit();

    var ctx = common.Context{
        .entities = &entities,
        .zcs_alloc = zcs_alloc,
        .client_manager = &client_manager,
        .ring = &ring,
        .buffer_pools = &buffer_pools,
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

    var running = true;
    while (running) {
        var cqe = try ring.waitCqe();

        while (true) {
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

                        var client = try ctx.addClient(cfd);
                        client.state = .handshake;
                        client.addr = addr;

                        try ring.prepareRead(cfd, &client.read_buf);
                    }

                    try ring.prepareAccept(server_fd, &addr, &addr_len);
                },
                .sigint => {
                    std.log.info("caught sigint", .{});
                    running = false;
                },
                .timer => {
                    try ring.prepareTimer(timer_fd, &tinfo);
                    scheduler.tick(&ctx);
                },
                .read => {
                    const cfd = ud.fd;
                    if (cqe.res < 0) {
                        const errcode: usize = @intCast(-cqe.res);
                        const err = std.posix.errno(errcode);
                        std.log.err("cqe error: read: {s}", .{@tagName(err)});
                        try ctx.removeClient(cfd);
                    } else {
                        if (client_manager.get(cfd)) |client| {
                            const bytes: usize = @intCast(cqe.res);
                            if (0 == bytes) {
                                if (client.state == .play) {
                                    dispatch(&ctx, "onQuit", .{client});
                                }
                                try ctx.removeClient(cfd);
                                std.log.debug("client: {d} disconnected", .{cfd});
                            } else {
                                client.read_buf_tail += bytes;

                                splitPackets(&ctx, client);

                                try ring.prepareRead(cfd, client.read_buf[client.read_buf_tail..]);
                            }
                        }
                    }
                },
                .write => {
                    const cfd = ud.fd;
                    if (cqe.res < 0) {
                        const errcode: usize = @intCast(-cqe.res);
                        const err = std.posix.errno(errcode);
                        std.log.err("cqe error: write: {s}", .{@tagName(err)});
                        try ctx.removeClient(cfd);
                    } else {
                        const idx: common.buffer.BufferIndex = @bitCast(ud.d);
                        const b = ctx.buffer_pools.get(idx);
                        b.ref_count -= 1;
                        if (0 == b.ref_count) {
                            ctx.buffer_pools.releaseBuf(idx);
                        }
                    }
                },
            }
            cqe = ring.peekCqe() orelse break;
        }

        _ = try ring.pump(&ctx);
        _ = try ring.submit();
    }

    // std.log.debug("busy buffers on exit: {d}", .{buffer_pool.busy_count});
}
