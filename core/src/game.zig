const std = @import("std");
const log = std.log.scoped(.game);

const SpscQueue = @import("spsc_queue").SpscQueue;

const common = @import("graphite-common");
const protocol = @import("graphite-protocol");

pub const Modules = .{
    @import("module/vanilla.zig").VanillaModule(.{
        .send_join_message = true,
        .send_quit_message = true,
    }),
    // @import("module/log.zig").LogModule(.{}),
};

pub const ModuleRegistry = common.ModuleRegistry(Modules);

fn keepaliveTask(ctx: *common.Context, _: u64) void {
    ctx.scheduler.schedule(&keepaliveTask, 200, 0) catch {};

    const b = ctx.buffer_pools.allocBuf(.@"6") catch return;

    const size = protocol.ClientPlayKeepAlive.encode(
        &.{ .id = protocol.types.VarInt{ .value = 67 } },
        b.ptr,
    ) catch return;

    ctx.prepareBroadcast(b, size);
}

fn dispatch(
    ctx: *common.Context,
    comptime method_name: []const u8,
    args: anytype,
) void {
    inline for (Modules) |ModuleType| {
        const instance = ctx.getModuleRegistry(ModuleRegistry).get(ModuleType);

        if (@hasDecl(ModuleType, method_name)) {
            const method = @field(ModuleType, method_name);
            const call_args = .{ instance, ctx } ++ args;
            const result = @call(.auto, method, call_args);

            const ReturnType = @typeInfo(@TypeOf(result));
            if (ReturnType == .error_union) {
                result catch |e| {
                    log.err(
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

pub fn main(efd: i32, rx: *SpscQueue(common.ServerMessage, true), tx: *SpscQueue(common.GameMessage, true)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const zcs_alloc = gpa.allocator();
    var entities = try common.zcs.Entities.init(.{
        .gpa = zcs_alloc,
    });
    defer entities.deinit(zcs_alloc);

    var client_manager = try common.client.ClientManager(common.client.Client).init(8, gpa.allocator(), gpa.allocator());
    defer client_manager.deinit();

    var buffer_pools = try common.buffer.BufferPools.init(gpa.allocator());
    defer buffer_pools.deinit();

    var scheduler = common.scheduler.Scheduler.init(gpa.allocator());
    defer scheduler.deinit();

    try scheduler.schedule(&keepaliveTask, 200, 0);

    var module_registry = try ModuleRegistry.init(gpa.allocator());
    defer module_registry.deinit();

    var ctx = common.Context{
        .entities = &entities,
        .zcs_alloc = zcs_alloc,
        .client_manager = &client_manager,
        .buffer_pools = &buffer_pools,
        .scheduler = &scheduler,
        .module_registry = &module_registry,
        .tx = tx,
        .efd = efd,
    };

    var running = true;
    while (running) {
        while (rx.front()) |msg| {
            switch (msg.*) {
                .tick => {
                    scheduler.tick(&ctx);
                },
                .write_result => |idx| {
                    const b = ctx.buffer_pools.get(idx);
                    b.ref_count -= 1;
                    if (0 == b.ref_count) {
                        ctx.buffer_pools.releaseBuf(idx);
                    }
                },
                .write_error => |idx| {
                    ctx.buffer_pools.releaseBuf(idx);
                },
                .status_request => |fd| {
                    dispatch(&ctx, "onStatus", .{fd});
                },
                .status_ping => |d| {
                    const b = try ctx.buffer_pools.allocBuf(.@"6");

                    b.ptr[0] = 9;
                    b.ptr[1] = 0x01;
                    @memcpy(b.ptr[2..10], @as([]const u8, @ptrCast(&d.payload)));

                    ctx.prepareOneshot(d.fd, b, 10);
                },
                .player_join => |d| {
                    log.debug("player {d} joined", .{d.fd});

                    var cb = try common.zcs.CmdBuf.init(.{ .name = null, .gpa = zcs_alloc, .es = &entities });
                    defer cb.deinit(zcs_alloc, &entities);

                    const e = common.zcs.Entity.reserve(&cb);
                    _ = e.add(&cb, common.ecs.Client, .{ .fd = d.fd });
                    _ = e.add(&cb, common.ecs.Location, .{
                        .x = 0.0,
                        .y = 67.0,
                        .z = 0.0,
                        .on_ground = false,
                    });

                    common.zcs.CmdBuf.Exec.immediate(&entities, &cb);

                    const c = try client_manager.add(d.fd);
                    c.fd = d.fd;
                    c.e = e;
                    c.username = std.ArrayListUnmanaged(u8).initBuffer(&c.username_buf);
                    c.username.appendSliceBounded(d.username[0..d.username_len]) catch unreachable;

                    var uuid_buf: [36]u8 = undefined;
                    msg.player_join.uuid = common.Uuid.random(std.crypto.random);
                    msg.player_join.uuid.stringify(&uuid_buf);

                    const b = try ctx.buffer_pools.allocBuf(.@"10");
                    errdefer ctx.buffer_pools.releaseBuf(b.idx);

                    var offset: usize = 0;

                    offset += try protocol.ClientLoginSuccess.encode(&.{
                        .uuid = &uuid_buf,
                        .username = c.username.items,
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
                    log.debug("client: {d}, username: '{s}'", .{ c.fd, c.username.items });

                    ctx.prepareOneshot(c.fd, b, offset);

                    dispatch(&ctx, "onJoin", .{c});
                },
                .player_move => |l| if (client_manager.get(l.fd)) |c| {
                    const lc = c.e.get(&entities, common.ecs.Location).?;
                    lc.x = l.d.x;
                    lc.y = l.d.y;
                    lc.z = l.d.z;
                    lc.on_ground = l.d.on_ground;

                    dispatch(&ctx, "onMove", .{c});
                },
                .player_chat => |d| if (client_manager.get(d.fd)) |c| {
                    dispatch(&ctx, "onChatMessage", .{ c, d.message[0..d.message_len] });
                },
                .player_quit => |fd| if (client_manager.get(fd)) |c| {
                    log.debug("player {d} left", .{fd});
                    dispatch(&ctx, "onQuit", .{c});

                    var cb = try common.zcs.CmdBuf.init(.{ .name = null, .gpa = zcs_alloc, .es = &entities });
                    defer cb.deinit(zcs_alloc, &entities);

                    c.e.destroy(&cb);

                    common.zcs.CmdBuf.Exec.immediate(&entities, &cb);

                    client_manager.remove(fd);
                },
                .stop => {
                    running = false;
                    break;
                },
            }
            rx.pop();
        }

        std.atomic.spinLoopHint();
    }

    inline for (std.meta.fields(common.buffer.BufferPools)) |field| {
        log.debug(
            "busy buffers on " ++ field.name ++ ": {d}",
            .{@field(buffer_pools, field.name).busy_count},
        );
    }
}
