const std = @import("std");

const client = @import("client.zig");
const uring = @import("uring.zig");

pub const BufferType = union(enum) {
    broadcast,
    oneshot,
};

pub const Buffer = struct {
    t: BufferType,
    idx: usize,
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

pub fn BufferPool(comptime buf_size: comptime_int) type {
    const B = BufferStorage(buf_size);

    return struct {
        idx_stack: []usize,
        busy_count: usize,
        buffers: []*B,
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, initial_cap: usize) !@This() {
            const res = @This(){
                .idx_stack = try alloc.alloc(usize, initial_cap),
                .busy_count = 0,
                .buffers = try alloc.alloc(*B, initial_cap),
                .alloc = alloc,
            };

            for (res.idx_stack, res.buffers, 0..) |*idx, *b, i| {
                idx.* = i;
                b.* = try alloc.create(B);
                b.*.header.idx = i;
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
                idx.* = i;
                b.* = try self.alloc.create(B);
                b.*.header.idx = i;
                b.*.header.ptr = b.*.data[0..buf_size];
            }
        }

        pub fn allocBuf(self: *@This()) !*Buffer {
            if (self.busy_count >= self.buffers.len) {
                try self.resize(self.buffers.len * 2);
            }

            const idx = self.idx_stack[self.busy_count];
            self.busy_count += 1;
            return &self.buffers[idx].header;
        }

        pub fn releaseBuf(self: *@This(), idx: usize) void {
            self.busy_count -= 1;
            self.idx_stack[self.busy_count] = idx;
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
