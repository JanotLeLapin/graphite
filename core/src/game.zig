const std = @import("std");
const log = std.log.scoped(.game);

const SpscQueue = @import("spsc_queue").SpscQueue;

const root = @import("root");

const common = @import("graphite-common");
const Buffer = common.buffer.Buffer;
const BufferPools = common.buffer.BufferPools;
const Client = common.client.Client;
const ClientManager = common.client.ClientManager(Client);
const ClientTag = common.types.ClientTag;
const Context = common.Context;
const EntityLocation = common.types.EntityLocation;
const Scheduler = common.scheduler.Scheduler;
const hook = common.hook;
const zcs = common.zcs;

const protocol = @import("graphite-protocol");

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
    hook_data: anytype,
) void {
    var cbo: ?zcs.CmdBuf = null;

    inline for (root.Modules) |ModuleType| {
        const instance = ctx.getModuleRegistry(root.ModuleRegistry).get(ModuleType);

        if (@hasDecl(ModuleType, method_name)) {
            const method = @field(ModuleType, method_name);
            const params = @typeInfo(@TypeOf(method)).@"fn".params;
            const CallArgsType = blk: {
                comptime var types: [params.len]type = undefined;
                inline for (params, 0..) |param, i| {
                    types[i] = if (param.type) |t| t else *root.ModuleRegistry;
                }
                break :blk std.meta.Tuple(&types);
            };
            var call_args: CallArgsType = undefined;
            comptime var passed = false;
            inline for (params, 0..) |param, i| {
                if (param.type) |pt| {
                    if (pt == @TypeOf(instance)) {
                        call_args[i] = instance;
                        continue;
                    }

                    const paramTypeInfo = @typeInfo(pt);
                    switch (paramTypeInfo) {
                        .pointer => |p| {
                            if (Context == p.child) {
                                call_args[i] = ctx;
                                continue;
                            }
                            if (zcs.CmdBuf == p.child) {
                                if (cbo == null) {
                                    cbo = zcs.CmdBuf.init(.{ .name = null, .gpa = ctx.zcs_alloc, .es = ctx.entities }) catch return;
                                }
                                call_args[i] = &cbo.?;
                                continue;
                            }
                            if (@typeInfo(p.child) == .@"opaque") {
                                call_args[i] = ctx.getModuleRegistry(root.ModuleRegistry);
                                continue;
                            }
                        },
                        else => {},
                    }
                    if (passed) {
                        @compileError("extra arg defined in hook");
                    } else {
                        call_args[i] = hook_data;
                        passed = true;
                    }
                } else {
                    call_args[i] = ctx.getModuleRegistry(root.ModuleRegistry);
                }
            }
            const result = @call(.always_inline, method, call_args);

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

    if (cbo != null) {
        zcs.CmdBuf.Exec.immediate(ctx.entities, &cbo.?);
        cbo.?.deinit(ctx.zcs_alloc, ctx.entities);
    }
}

pub fn main(running: *std.atomic.Value(bool), efd: i32, rx: *SpscQueue(root.ServerMessage, true), tx: *SpscQueue(common.GameMessage, true)) !void {
    defer running.store(false, .monotonic);
    const v: u64 = 0;
    defer _ = std.os.linux.write(efd, std.mem.asBytes(&v), 8);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const zcs_alloc = gpa.allocator();
    var entities = try zcs.Entities.init(.{
        .gpa = zcs_alloc,
    });
    defer entities.deinit(zcs_alloc);

    var client_manager = try ClientManager.init(8, gpa.allocator(), gpa.allocator());
    defer client_manager.deinit();

    var buffer_pools = try BufferPools.init(gpa.allocator());
    defer buffer_pools.deinit();

    var scheduler = Scheduler.init(gpa.allocator());
    defer scheduler.deinit();

    try scheduler.schedule(&keepaliveTask, 200, 0);

    var module_registry = try root.ModuleRegistry.init(gpa.allocator());
    defer module_registry.deinit();

    var ctx = Context{
        .entities = &entities,
        .zcs_alloc = zcs_alloc,
        .client_manager = &client_manager,
        .buffer_pools = &buffer_pools,
        .scheduler = &scheduler,
        .module_registry = &module_registry,
        .tx = tx,
        .efd = efd,
    };

    while (running.load(.monotonic)) {
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
                .packet => |p| {
                    switch (p.d) {
                        .status_request => {
                            dispatch(&ctx, "onStatus", hook.StatusHook{ .fd = p.fd });
                        },
                        .status_ping => |d| {
                            const b = try ctx.buffer_pools.allocBuf(.@"6");

                            b.ptr[0] = 9;
                            b.ptr[1] = 0x01;
                            @memcpy(b.ptr[2..10], @as([]const u8, @ptrCast(&d.payload)));

                            ctx.prepareOneshot(p.fd, b, 10);
                        },
                        else => if (client_manager.get(p.fd)) |c| {
                            switch (p.d) {
                                .play_player_position => |d| {
                                    dispatch(&ctx, "onMove", hook.MoveHook{
                                        .client = c,
                                        .location = EntityLocation{
                                            .x = d.x,
                                            .y = d.y,
                                            .z = d.z,
                                            .on_ground = d.on_ground,
                                        },
                                    });
                                },
                                .play_player_position_and_look => |d| {
                                    dispatch(&ctx, "onMove", hook.MoveHook{
                                        .client = c,
                                        .location = EntityLocation{
                                            .x = d.x,
                                            .y = d.y,
                                            .z = d.z,
                                            .on_ground = d.on_ground,
                                        },
                                    });
                                },
                                .play_player_digging => |d| {
                                    dispatch(&ctx, "onDig", hook.DigHook{
                                        .client = c,
                                        .status = d.status,
                                        .location = d.location,
                                        .face = d.face,
                                    });
                                },
                                else => {},
                            }
                        },
                    }
                },
                .player_join => |d| {
                    log.debug("player {d} joined", .{d.fd});

                    var cb = try zcs.CmdBuf.init(.{ .name = null, .gpa = zcs_alloc, .es = &entities });
                    defer cb.deinit(zcs_alloc, &entities);

                    const e = zcs.Entity.reserve(&cb);
                    _ = e.add(&cb, ClientTag, .{ .fd = d.fd });

                    zcs.CmdBuf.Exec.immediate(&entities, &cb);

                    const c = try client_manager.add(d.fd);
                    c.fd = d.fd;
                    c.e = e;
                    c.username = std.ArrayListUnmanaged(u8).initBuffer(&c.username_buf);
                    c.username.appendSliceBounded(d.username[0..d.username_len]) catch unreachable;
                    c.addr = d.addr;

                    var uuid_buf: [36]u8 = undefined;
                    c.uuid = common.Uuid.random(std.crypto.random);
                    c.uuid.stringify(&uuid_buf);

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

                    dispatch(&ctx, "onJoin", hook.JoinHook{ .client = c });
                },
                .player_chat => |d| if (client_manager.get(d.fd)) |c| {
                    dispatch(&ctx, "onChatMessage", hook.ChatMessageHook{
                        .client = c,
                        .message = d.message[0..d.message_len],
                    });
                },
                .player_quit => |fd| if (client_manager.get(fd)) |c| {
                    log.debug("player {d} left", .{fd});
                    dispatch(&ctx, "onQuit", hook.QuitHook{ .client = c });

                    var cb = try zcs.CmdBuf.init(.{ .name = null, .gpa = zcs_alloc, .es = &entities });
                    defer cb.deinit(zcs_alloc, &entities);

                    c.e.destroy(&cb);

                    zcs.CmdBuf.Exec.immediate(&entities, &cb);

                    client_manager.remove(fd);
                },
                .stop => {
                    break;
                },
            }
            rx.pop();
        }

        std.atomic.spinLoopHint();
    }

    inline for (std.meta.fields(BufferPools)) |field| {
        log.debug(
            "busy buffers on " ++ field.name ++ ": {d}",
            .{@field(buffer_pools, field.name).busy_count},
        );
    }
}
