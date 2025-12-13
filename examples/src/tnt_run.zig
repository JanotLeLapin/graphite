const std = @import("std");

const common = @import("graphite-common");
const BlockLocation = common.types.BlockLocation;
const BlockType = common.types.chunk.BlockType;
const Chat = common.chat.Chat;
const Chunk = common.types.chunk.Chunk;
const Client = common.client.Client;
const Context = common.Context;
const WoolColor = common.types.chunk.WoolColor;

const protocol = @import("graphite-protocol");

const BlockPos = packed struct(u64) {
    x: i32,
    z: i32,
};

const InitialMap: [4]Chunk = blk: {
    @setEvalBranchQuota(4096);
    var chunks: [4]Chunk = undefined;
    for (0..2) |cx| {
        for (0..2) |cz| {
            const ci = cx << 1 | cz;
            for (0..16) |x| {
                for (0..16) |z| {
                    const i = z << 4 | x;
                    const abs_x = x + 16 * cx;
                    const abs_z = z + 16 * cz;

                    const meta: WoolColor =
                        if ((abs_x + abs_z) % 2 == 0) .white else .black;

                    chunks[ci].sections[4].blocks[i] = BlockType.wool.getBlockDataMeta(meta);
                    chunks[ci].sections[4].block_light[i] = 15;
                    chunks[ci].sections[4].sky_light[i] = 15;
                }
            }

            for (&chunks[ci].biomes) |*biome| {
                biome.* = .plains;
            }
        }
    }
    break :blk chunks;
};

const InitialMapMeta: [4]protocol.ChunkMeta = blk: {
    var meta: [4]protocol.ChunkMeta = undefined;
    for (0..2) |cx| {
        for (0..2) |cz| {
            const ci = cx << 1 | cz;
            meta[ci].bit_mask = 1 << 4;
            meta[ci].x = @as(i32, @intCast(cx)) - 1;
            meta[ci].z = @as(i32, @intCast(cz)) - 1;
        }
    }
    break :blk meta;
};

fn scheduleTimer(ctx: *Context, ud: u64) void {
    const b = ctx.buffer_pools.allocBuf(.@"14") catch return;

    var offset: usize = 0;
    if (ud > 0) {
        offset += (protocol.ClientPlaySoundEffect{
            .pitch = common.pitchFromMidi(62 - 12),
            .sound_name = "note.pling",
            .x = 0,
            .y = 64,
            .z = 0,
            .volume = 10.0,
        }).encode(b.ptr[offset..]) catch {
            ctx.buffer_pools.releaseBuf(b.idx);
            return;
        };
    } else {
        offset += (protocol.ClientPlaySoundEffect{
            .pitch = common.pitchFromMidi(62),
            .sound_name = "note.pling",
            .x = 0,
            .y = 64,
            .z = 0,
            .volume = 100.0,
        }).encode(b.ptr[offset..]) catch {
            ctx.buffer_pools.releaseBuf(b.idx);
            return;
        };
    }

    offset += switch (ud) {
        3 => (protocol.ClientPlayTitle{ .set_title = "{\"text\":\"3\",\"color\":\"green\"}" }).encode(b.ptr[offset..]),
        2 => (protocol.ClientPlayTitle{ .set_title = "{\"text\":\"2\",\"color\":\"yellow\"}" }).encode(b.ptr[offset..]),
        1 => (protocol.ClientPlayTitle{ .set_title = "{\"text\":\"1\",\"color\":\"red\"}" }).encode(b.ptr[offset..]),
        0 => (protocol.ClientPlayTitle{ .set_title = "{\"text\":\"Go\",\"color\":\"aqua\"}" }).encode(b.ptr[offset..]),
        else => return,
    } catch {
        ctx.buffer_pools.releaseBuf(b.idx);
        return;
    };

    ctx.prepareBroadcast(b, offset);
}

fn scheduleRemove(ctx: *Context, ud: u64) void {
    const pos: BlockPos = @bitCast(ud);
    const b = ctx.buffer_pools.allocBuf(.@"10") catch return;

    const size = (protocol.ClientPlayBlockChange{
        .block_id = protocol.types.VarInt{ .value = 0 },
        .location = BlockLocation{ .x = pos.x, .y = 64, .z = pos.z },
    }).encode(b.ptr) catch {
        ctx.buffer_pools.releaseBuf(b.idx);
        return;
    };

    ctx.prepareBroadcast(b, size);
}

fn scheduleStart(_: *Context, ud: u64) void {
    const running: *bool = @ptrFromInt(ud);
    running.* = true;
}

pub const TntRunModuleOptions = struct {
    location_mod: type,
};

pub fn TntRunModule(opt: TntRunModuleOptions) type {
    return struct {
        running: bool = false,
        chunks: [4]Chunk = InitialMap,

        pub fn init(_: std.mem.Allocator) !@This() {
            return @This(){};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn onJoin(
            self: *@This(),
            reg: anytype,
            cb: *zcs.CmdBuf,
            ctx: *Context,
            client: *Client,
        ) !void {
            _ = reg.get(opt.location_mod); // check location module

            const b = try ctx.buffer_pools.allocBuf(.@"18");
            errdefer ctx.buffer_pools.releaseBuf(b.idx);

            const size = try (protocol.ClientPlayMapChunkBulk{
                .chunk_data = &self.chunks,
                .chunk_meta = &InitialMapMeta,
                .sky_light = true,
            }).encode(b.ptr);
            ctx.prepareOneshot(client.fd, b, size);
        }

        pub fn onChatMessage(
            self: *@This(),
            ctx: *Context,
            _: *Client,
            message: []const u8,
        ) !void {
            if (std.mem.eql(u8, "start", message)) {
                const b = try ctx.buffer_pools.allocBuf(.@"10");
                var offset = (protocol.ClientPlayPlayerPositionAndLook{
                    .x = 0.0,
                    .y = 67.0,
                    .z = 0.0,
                    .flags = 0,
                    .pitch = 0,
                    .yaw = 0,
                }).encode(b.ptr) catch return;
                offset += (protocol.ClientPlayChangeGameState{
                    .change_game_mode = .survival,
                }).encode(b.ptr[offset..]) catch return;

                ctx.prepareBroadcast(b, offset);

                try ctx.scheduler.schedule(&scheduleTimer, 0, 3);
                try ctx.scheduler.schedule(&scheduleTimer, 20, 2);
                try ctx.scheduler.schedule(&scheduleTimer, 40, 1);
                try ctx.scheduler.schedule(&scheduleTimer, 60, 0);
                try ctx.scheduler.schedule(&scheduleStart, 60, @intFromPtr(&self.running));
            } else if (std.mem.eql(u8, "stop", message)) {
                self.running = false;
            }
        }

        pub fn onMove(
            self: *@This(),
            ctx: *Context,
            client: *Client,
        ) !void {
            if (!self.running) {
                return;
            }

            const l = client.e.get(ctx.entities, common.types.EntityLocation).?;

            if (l.y < 50) {
                self.running = false;

                var buf: [256]u8 = undefined;
                const b = try ctx.buffer_pools.allocBuf(.@"10");
                errdefer ctx.buffer_pools.releaseBuf(b.idx);

                var offset = try (protocol.ClientPlayChatMessage{
                    .json = try std.fmt.bufPrint(
                        buf[0..],
                        "{f}",
                        .{common.chat.Chat{
                            .text = "",
                            .color = .yellow,
                            .extra = &.{
                                .{ .text = client.username.items, .color = .red },
                                .{ .text = " est un gros loser" },
                            },
                        }},
                    ),
                    .position = .system,
                }).encode(b.ptr);
                offset += try (protocol.ClientPlayChangeGameState{
                    .change_game_mode = .spectator,
                }).encode(b.ptr[offset..]);

                ctx.prepareBroadcast(b, offset);
                return;
            }

            if (!l.on_ground) {
                return;
            }

            const x: i32 = @intFromFloat(@floor(l.x));
            const z: i32 = @intFromFloat(@floor(l.z));

            try ctx.scheduler.schedule(&scheduleRemove, 10, @bitCast(BlockPos{ .x = x, .z = z }));
        }
    };
}
