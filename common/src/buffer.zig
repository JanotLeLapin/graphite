const std = @import("std");

const client = @import("client.zig");

pub const BufferType = union(enum) {
    broadcast,
    oneshot,
};

pub const BufferSize = enum(u2) {
    @"6",
    @"10",
    @"14",
    @"18",
};

pub const BufferIndex = packed struct(u28) {
    size: BufferSize,
    index: u26,
};

pub const Buffer = struct {
    t: BufferType,
    idx: BufferIndex,
    size: usize,
    ref_count: usize,
    ptr: []u8,
};

pub fn BufferStorage(comptime size: comptime_int) type {
    return struct {
        header: Buffer,
        data: [size]u8,
    };
}

pub fn BufferPool(
    comptime buf_size: comptime_int,
    comptime buf_size_type: BufferSize,
) type {
    const B = BufferStorage(buf_size);

    return struct {
        idx_stack: []BufferIndex,
        busy_count: usize,
        buffers: []*B,
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, initial_cap: usize) !@This() {
            const res = @This(){
                .idx_stack = try alloc.alloc(BufferIndex, initial_cap),
                .busy_count = 0,
                .buffers = try alloc.alloc(*B, initial_cap),
                .alloc = alloc,
            };

            for (res.idx_stack, res.buffers, 0..) |*idx, *b, i| {
                idx.* = .{ .size = buf_size_type, .index = @intCast(i) };
                b.* = try alloc.create(B);
                b.*.header.idx = idx.*;
                b.*.header.ptr = b.*.data[0..buf_size];
            }

            return res;
        }

        fn resize(self: *@This(), new_size: usize) !void {
            const old_size = self.buffers.len;
            self.idx_stack = try self.alloc.realloc(self.idx_stack, new_size);
            self.buffers = try self.alloc.realloc(self.buffers, new_size);

            for (
                self.idx_stack[old_size..new_size],
                self.buffers[old_size..new_size],
                old_size..new_size,
            ) |*idx, *b, i| {
                idx.* = .{ .size = buf_size_type, .index = @intCast(i) };
                b.* = try self.alloc.create(B);
                b.*.header.idx = idx.*;
                b.*.header.ptr = b.*.data[0..buf_size];
            }
        }

        pub fn allocBuf(self: *@This()) !*Buffer {
            if (self.busy_count >= self.buffers.len) {
                try self.resize(self.buffers.len * 2);
            }

            const idx = self.idx_stack[self.busy_count];
            self.busy_count += 1;
            return &self.buffers[idx.index].header;
        }

        pub fn releaseBuf(self: *@This(), idx: usize) void {
            self.busy_count -= 1;
            self.idx_stack[self.busy_count] = .{ .size = buf_size_type, .index = @intCast(idx) };
        }

        pub fn deinit(self: *@This()) void {
            for (self.buffers) |b| {
                self.alloc.destroy(b);
            }
            self.alloc.free(self.idx_stack);
            self.alloc.free(self.buffers);
        }
    };
}

pub const BufferPools = struct {
    @"6": BufferPool(2 << 6, .@"6"),
    @"10": BufferPool(2 << 10, .@"10"),
    @"14": BufferPool(2 << 14, .@"14"),
    @"18": BufferPool(2 << 18, .@"18"),

    pub fn init(alloc: std.mem.Allocator) !BufferPools {
        return BufferPools{
            .@"6" = try BufferPool(2 << 6, .@"6").init(alloc, 1024),
            .@"10" = try BufferPool(2 << 10, .@"10").init(alloc, 512),
            .@"14" = try BufferPool(2 << 14, .@"14").init(alloc, 256),
            .@"18" = try BufferPool(2 << 18, .@"18").init(alloc, 128),
        };
    }

    pub fn allocBuf(self: *BufferPools, comptime size: BufferSize) !*Buffer {
        return switch (size) {
            .@"6" => try self.@"6".allocBuf(),
            .@"10" => try self.@"10".allocBuf(),
            .@"14" => try self.@"14".allocBuf(),
            .@"18" => try self.@"18".allocBuf(),
        };
    }

    pub fn get(self: *BufferPools, idx: BufferIndex) *Buffer {
        return switch (idx.size) {
            .@"6" => &self.@"6".buffers[idx.index].header,
            .@"10" => &self.@"10".buffers[idx.index].header,
            .@"14" => &self.@"14".buffers[idx.index].header,
            .@"18" => &self.@"18".buffers[idx.index].header,
        };
    }

    pub fn releaseBuf(self: *BufferPools, idx: BufferIndex) void {
        switch (idx.size) {
            .@"6" => self.@"6".releaseBuf(idx.index),
            .@"10" => self.@"10".releaseBuf(idx.index),
            .@"14" => self.@"14".releaseBuf(idx.index),
            .@"18" => self.@"18".releaseBuf(idx.index),
        }
    }

    pub fn deinit(self: *BufferPools) void {
        self.@"6".deinit();
        self.@"10".deinit();
        self.@"14".deinit();
        self.@"18".deinit();
    }
};
