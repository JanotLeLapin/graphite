const std = @import("std");

const common = @import("graphite-common");
const protocol = @import("graphite-protocol");

const BlockPos = packed struct(u64) {
    x: i32,
    z: i32,
};

fn scheduleTimer(ctx: *common.Context, ud: u64) void {
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
        const mod = common.ModuleRegistry.get(&ctx.module_registry, TntRunModule);
        mod.running = true;
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

    ctx.ring.prepareBroadcast(ctx, b, offset) catch {};
}

fn scheduleRemove(ctx: *common.Context, ud: u64) void {
    const pos: BlockPos = @bitCast(ud);
    const b = ctx.buffer_pools.allocBuf(.@"10") catch return;

    const size = (protocol.ClientPlayBlockChange{
        .block_id = protocol.types.VarInt{ .value = 0 },
        .location = protocol.types.Location{
            .value = common.chunk.Location{ .x = pos.x, .y = 64, .z = pos.z },
        },
    }).encode(b.ptr) catch {
        ctx.buffer_pools.releaseBuf(b.idx);
        return;
    };

    ctx.ring.prepareBroadcast(ctx, b, size) catch {};
}

pub const TntRunModule = struct {
    running: bool = false,
    chunks: [4]common.chunk.Chunk = blk: {
        @setEvalBranchQuota(4096);
        var chunks: [4]common.chunk.Chunk = undefined;
        for (0..2) |cx| {
            for (0..2) |cz| {
                const ci = cx << 1 | cz;
                for (0..16) |x| {
                    for (0..16) |z| {
                        const i = z << 4 | x;
                        const abs_x = x + 16 * cx;
                        const abs_z = z + 16 * cz;

                        const meta = if ((abs_x + abs_z) % 2 == 0) 0 else 15;

                        chunks[ci].sections[3].blocks[i] = common.chunk.BlockData(.wool, meta);
                        chunks[ci].sections[3].block_light[i] = 15;
                        chunks[ci].sections[3].sky_light[i] = 15;
                    }
                }

                for (&chunks[ci].biomes) |*biome| {
                    biome.* = .plains;
                }
            }
        }
        break :blk chunks;
    },

    pub fn init(_: std.mem.Allocator) !@This() {
        return @This(){};
    }

    pub fn deinit(_: *@This()) void {}

    pub fn onChatMessage(
        self: *@This(),
        ctx: *common.Context,
        _: *common.client.Client,
        message: []const u8,
    ) !void {
        if (std.mem.eql(u8, "start", message)) {
            try ctx.scheduler.schedule(&scheduleTimer, 0, 3);
            try ctx.scheduler.schedule(&scheduleTimer, 20, 2);
            try ctx.scheduler.schedule(&scheduleTimer, 40, 1);
            try ctx.scheduler.schedule(&scheduleTimer, 60, 0);
        } else if (std.mem.eql(u8, "stop", message)) {
            self.running = false;
        }
    }

    pub fn onMove(
        self: *@This(),
        ctx: *common.Context,
        client: *common.client.Client,
    ) !void {
        if (!self.running) {
            return;
        }

        const l = client.e.get(ctx.entities, common.ecs.Location).?;

        if (l.y < 50) {
            self.running = false;

            var buf: [256]u8 = undefined;
            const b = try ctx.buffer_pools.allocBuf(.@"10");
            errdefer ctx.buffer_pools.releaseBuf(b.idx);

            const size = try (protocol.ClientPlayChatMessage{
                .json = try std.fmt.bufPrint(
                    buf[0..],
                    "{f}",
                    .{common.chat.Chat{
                        .text = "",
                        .color = .yellow,
                        .extra = &[_]common.chat.Chat{
                            .{ .text = client.username.items, .color = .red },
                            .{ .text = " est un gros loser" },
                        },
                    }},
                ),
                .position = .system,
            }).encode(b.ptr);

            try ctx.ring.prepareBroadcast(ctx, b, size);
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
