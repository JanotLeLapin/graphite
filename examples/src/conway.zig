// inspired by the Valence example showcase
// https://youtu.be/jkw9fZx9Etg
// cool framework

const std = @import("std");

const common = @import("graphite-common");
const protocol = @import("graphite-protocol");

pub const ConwayModuleOptions = struct {
    /// dimensions of the game of life grid
    dim: usize = 32,
    tick_speed: usize = 4,
    block_alive: u16,
    block_dead: u16,
};

pub fn ConwayModule(comptime opt: ConwayModuleOptions) type {
    const GridSize = opt.dim * opt.dim;
    const ChunkRowCount = opt.dim / 16;
    const ChunkCount = ChunkRowCount * ChunkRowCount;

    const EmptyGrid = blk: {
        var res: [GridSize]bool = undefined;
        @memset(&res, false);
        break :blk res;
    };

    return struct {
        grid: [GridSize]bool = EmptyGrid,
        tmp_grid: [GridSize]bool = EmptyGrid,
        running: bool = false,

        fn flipBlock(
            self: *@This(),
            ctx: *common.Context,
            x: i32,
            z: i32,
        ) !void {
            const flag = &self.grid[@as(usize, @intCast(x)) * opt.dim + @as(usize, @intCast(z))];
            flag.* = !flag.*;

            const block = if (flag.*)
                opt.block_alive
            else
                opt.block_dead;

            const b = try ctx.buffer_pools.allocBuf(.@"10");
            errdefer ctx.buffer_pools.releaseBuf(b.idx);

            const size = try (protocol.ClientPlayBlockChange{
                .block_id = protocol.types.VarInt{ .value = @intCast(block) },
                .location = common.chunk.Location{ .x = x, .y = 64, .z = z },
            }).encode(b.ptr);
            ctx.prepareBroadcast(b, size);
        }

        /// basic Game of Life implementation, not exactly optimal
        fn schedule(ctx: *common.Context, ud: u64) void {
            const self: *@This() = @ptrFromInt(ud);
            @memcpy(&self.tmp_grid, &self.grid);

            if (!self.running) {
                return;
            }

            var c: usize = 0;
            for (0..GridSize) |i| {
                c = 0;

                const ix: i32 = @intCast(@divTrunc(i, opt.dim));
                const iz: i32 = @intCast(i % opt.dim);

                for (0..9) |j| {
                    if (j == 4) {
                        continue;
                    }

                    const jx: i32 = @intCast(@divTrunc(j, 3));
                    const jz: i32 = @intCast(j % 3);

                    const x = @min(@max(ix + jx - 1, 0), opt.dim - 1);
                    const z = @min(@max(iz + jz - 1, 0), opt.dim - 1);
                    const idx = x * opt.dim + z;

                    if (self.grid[idx]) {
                        c += 1;
                    }
                }

                switch (self.grid[i]) {
                    true => if (c <= 1 or c > 3) {
                        self.tmp_grid[i] = false;
                    },
                    false => if (c == 3) {
                        self.tmp_grid[i] = true;
                    },
                }
            }

            for (0..GridSize) |i| {
                if (self.grid[i] != self.tmp_grid[i]) {
                    const ix: i32 = @intCast(@divTrunc(i, opt.dim));
                    const iz: i32 = @intCast(i % opt.dim);
                    self.flipBlock(ctx, @intCast(ix), @intCast(iz)) catch {};
                }
            }

            ctx.scheduler.schedule(&schedule, opt.tick_speed, ud) catch {};
        }

        pub fn init(_: std.mem.Allocator) !@This() {
            return @This(){};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn onJoin(
            self: *@This(),
            ctx: *common.Context,
            _: anytype,
            client: *common.client.Client,
        ) !void {
            var chunks: [ChunkCount]common.chunk.Chunk = undefined;
            var meta: [ChunkCount]protocol.ChunkMeta = undefined;

            for (0..ChunkRowCount) |cx| {
                for (0..ChunkRowCount) |cz| {
                    const ci = cx * ChunkRowCount + cz;

                    for (&chunks[ci].biomes) |*biome| {
                        biome.* = .plains;
                    }

                    for (&chunks[ci].sections) |*section| {
                        @memset(&section.block_light, 15);
                        @memset(&section.sky_light, 15);
                        @memset(&section.blocks, 0);
                    }

                    meta[ci].bit_mask = 1 << 4;
                    meta[ci].x = @as(i32, @intCast(cx));
                    meta[ci].z = @as(i32, @intCast(cz));
                }
            }

            for (0..opt.dim) |x| {
                for (0..opt.dim) |z| {
                    const block = if (self.grid[x * opt.dim + z])
                        opt.block_alive
                    else
                        opt.block_dead;

                    const cx = @divTrunc(x, 16);
                    const cz = @divTrunc(z, 16);
                    const ci = cx * ChunkRowCount + cz;

                    const bx = x % 16;
                    const bz = z % 16;
                    const bi = bx << 4 | bz;

                    chunks[ci].sections[4].blocks[bi] = block;
                }
            }

            const b = try ctx.buffer_pools.allocBuf(.@"18");
            errdefer ctx.buffer_pools.releaseBuf(b.idx);

            const size = try (protocol.ClientPlayMapChunkBulk{
                .chunk_data = &chunks,
                .chunk_meta = &meta,
                .sky_light = true,
            }).encode(b.ptr);

            ctx.prepareOneshot(client.fd, b, size);
        }

        pub fn onDig(
            self: *@This(),
            ctx: *common.Context,
            _: anytype,
            _: *common.client.Client,
            d: protocol.ServerPlayPlayerDigging,
        ) !void {
            if (d.status != .cancelled_digging and d.status != .finished_digging) {
                return;
            }

            try self.flipBlock(ctx, @intCast(d.location.x), @intCast(d.location.z));
        }

        pub fn onChatMessage(
            self: *@This(),
            ctx: *common.Context,
            _: anytype,
            _: *common.client.Client,
            message: []const u8,
        ) !void {
            if (std.mem.eql(u8, message, "conway")) {
                switch (self.running) {
                    true => {
                        const b = try ctx.buffer_pools.allocBuf(.@"10");
                        const size = try (protocol.ClientPlayChangeGameState{ .change_game_mode = .survival }).encode(b.ptr);
                        ctx.prepareBroadcast(b, size);
                    },
                    false => {
                        const b = try ctx.buffer_pools.allocBuf(.@"10");
                        const size = try (protocol.ClientPlayChangeGameState{ .change_game_mode = .creative }).encode(b.ptr);
                        ctx.prepareBroadcast(b, size);
                        try ctx.scheduler.schedule(&schedule, 0, @intFromPtr(self));
                    },
                }
                self.running = !self.running;
            }
        }
    };
}
