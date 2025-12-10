const std = @import("std");

const log = std.log.scoped(.server);

const SpscQueue = @import("spsc_queue").SpscQueue;

const root = @import("root");
const common = @import("graphite-common");
const protocol = @import("graphite-protocol");
const uring = @import("uring.zig");

const PORT = 25565;
const ADDRESS = "0.0.0.0";

const URING_QUEUE_ENTRIES = 4096;

pub const Client = struct {
    fd: i32,
    state: protocol.ClientState,
    read_buf: [4096]u8,
    read_buf_tail: usize,
    addr: std.os.linux.sockaddr,
};

pub const Context = struct {
    ring: *uring.Ring,
    client_manager: *common.client.ClientManager(Client),
    tx: *SpscQueue(common.ServerMessage, true),
};

const PacketProcessingError = error{
    EncodingFailure,
};

fn processPacket(
    ctx: *Context,
    client: *Client,
    p: protocol.ServerBoundPacket,
) !void {
    switch (p) {
        .handshake => client.state = @enumFromInt(p.handshake.next_state),
        .status_request => {
            ctx.tx.push(.{ .status_request = client.fd });
        },
        .status_ping => {
            ctx.tx.push(.{ .status_ping = .{
                .fd = client.fd,
                .payload = p.status_ping.payload,
            } });
        },
        .login_start => {
            var msg = common.ServerMessage{ .player_join = .{
                .fd = client.fd,
                .username = undefined,
                .username_len = 0,
                .uuid = undefined,
                .location = .{
                    .x = 0.0,
                    .y = 67.0,
                    .z = 0.0,
                    .on_ground = false,
                },
            } };
            msg.player_join.username_len = @min(p.login_start.username.len, 63);
            @memcpy(msg.player_join.username[0..msg.player_join.username_len], p.login_start.username[0..msg.player_join.username_len]);

            client.state = .play;

            ctx.tx.push(msg);
        },
        .play_chat_message => |pd| {
            const len = @min(pd.message.len, 128);
            var msg = common.ServerMessage{ .player_chat = .{
                .fd = client.fd,
                .message_len = len,
                .message = undefined,
            } };

            @memcpy(msg.player_chat.message[0..len], pd.message[0..len]);
            ctx.tx.push(msg);
        },
        .play_player_position => |pd| {
            ctx.tx.push(.{ .player_move = .{
                .fd = client.fd,
                .d = .{
                    .x = pd.x,
                    .y = pd.y,
                    .z = pd.z,
                    .on_ground = pd.on_ground,
                },
            } });
        },
        .play_player_position_and_look => |pd| {
            ctx.tx.push(.{ .player_move = .{
                .fd = client.fd,
                .d = .{
                    .x = pd.x,
                    .y = pd.y,
                    .z = pd.z,
                    .on_ground = pd.on_ground,
                },
            } });
        },
        else => {},
    }
}

fn splitPackets(ctx: *Context, client: *Client) void {
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
            log.debug("client: {d}, failed to process packet with id {x}: {s}", .{ client.fd, id.value, @errorName(e) });
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

pub fn main(efd: i32, rx: *SpscQueue(common.GameMessage, true), tx: *SpscQueue(common.ServerMessage, true)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var client_manager = try common.client.ClientManager(Client).init(8, gpa.allocator(), gpa.allocator());
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

    log.info("server listening on port {d}.", .{PORT});

    var ring = try uring.Ring.init(gpa.allocator(), URING_QUEUE_ENTRIES);
    defer ring.deinit();

    var ctx = Context{
        .client_manager = &client_manager,
        .ring = &ring,
        .tx = tx,
    };

    {
        const sqe = try ring.getSqe();
        sqe.prep_accept(server_fd, &addr, &addr_len, 0);
        sqe.user_data = @bitCast(uring.Userdata{ .op = .accept, .d = 0, .fd = 0 });
    }

    {
        const sqe = try ring.getSqe();
        sqe.prep_read(sig_fd, @ptrCast(&siginfo), 0);
        sqe.user_data = @bitCast(uring.Userdata{ .op = .sigint, .d = 0, .fd = 0 });
    }

    {
        const sqe = try ring.getSqe();
        sqe.prep_read(timer_fd, @ptrCast(&tinfo), 0);
        sqe.user_data = @bitCast(uring.Userdata{ .op = .timer, .d = 0, .fd = 0 });
    }

    {
        const sqe = try ring.getSqe();
        sqe.prep_poll_add(efd, std.os.linux.POLL.IN);
        sqe.user_data = @bitCast(uring.Userdata{ .op = .event, .d = 0, .fd = 0 });
    }

    _ = try ring.submit();

    var running = true;
    while (running) {
        var cqe = try ring.waitCqe();

        while (true) {
            const ud: uring.Userdata = @bitCast(cqe.user_data);
            switch (ud.op) {
                .accept => {
                    if (cqe.res < 0) {
                        const errcode: usize = @intCast(-cqe.res);
                        const err = std.posix.errno(errcode);
                        log.err("cqe error: accept: {s}", .{@tagName(err)});
                    } else {
                        const cfd = cqe.res;
                        log.debug("client: {d} connected", .{cfd});

                        var client = try client_manager.add(cfd);
                        client.fd = cfd;
                        client.read_buf_tail = 0;
                        client.state = .handshake;
                        client.addr = addr;

                        try ring.prepareRead(cfd, &client.read_buf);
                    }

                    try ring.prepareAccept(server_fd, &addr, &addr_len);
                },
                .sigint => {
                    log.info("caught sigint", .{});
                    tx.push(.{ .stop = {} });
                    running = false;
                },
                .timer => {
                    try ring.prepareTimer(timer_fd, &tinfo);
                    tx.push(.{ .tick = {} });
                },
                .event => {
                    try ring.prepareEvent(efd);
                    while (rx.front()) |msg| {
                        switch (msg.*) {
                            .prepare_oneshot => |d| {
                                ring.prepareOneshot(d.fd, d.b, d.size) catch {
                                    log.warn("memory leak!", .{});
                                };
                            },
                            .prepare_broadcast => |d| {
                                ring.prepareBroadcast(&ctx, d.b, d.size) catch {
                                    log.warn("memory leak!", .{});
                                };
                            },
                        }
                        rx.pop();
                    }
                },
                .read => {
                    const cfd = ud.fd;
                    if (client_manager.get(cfd)) |client| {
                        if (cqe.res < 0) {
                            const errcode: usize = @intCast(-cqe.res);
                            const err = std.posix.errno(errcode);
                            log.err("cqe error: read: {s}", .{@tagName(err)});
                            if (client.state == .play) {
                                tx.push(.{ .player_quit = cfd });
                            }
                            client_manager.remove(cfd);
                        } else {
                            const bytes: usize = @intCast(cqe.res);
                            if (0 == bytes) {
                                if (client.state == .play) {
                                    tx.push(.{ .player_quit = cfd });
                                }
                                client_manager.remove(cfd);
                                log.debug("client: {d} disconnected", .{cfd});
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
                        log.err("cqe error: write: {s}", .{@tagName(err)});
                        if (client_manager.get(cfd)) |c| {
                            if (c.state == .play) {
                                tx.push(.{ .player_quit = cfd });
                            }
                        }
                        client_manager.remove(cfd);
                    } else if (cqe.res > 0) {} else {
                        tx.push(.{ .write_result = @bitCast(ud.d) });
                    }
                },
            }
            cqe = ring.peekCqe() orelse break;
        }

        _ = try ring.pump(&ctx);
        _ = try ring.submit();
    }
}
