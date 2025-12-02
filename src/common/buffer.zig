const std = @import("std");

pub const BufferType = union(enum) {
    Broadcast,
    Oneshot,
};

pub fn Buffer(comptime size: comptime_int) type {
    return struct {
        t: BufferType,
        data: [size]u8,
        size: usize,
    };
}

pub fn BufferPool(comptime buf_size: comptime_int, comptime cap: comptime_int) type {
    const B = Buffer(buf_size);

    return struct {
        idx_stack: [cap]usize,
        stack_head: usize,
        buffers: []B,
        buf_alloc: std.mem.Allocator,

        pub fn init(buf_alloc: std.mem.Allocator) !@This() {
            var res = @This(){
                .idx_stack = undefined,
                .stack_head = cap - 1,
                .buffers = try buf_alloc.alloc(B, cap),
                .buf_alloc = buf_alloc,
            };

            for (&res.idx_stack, 0..) |*idx, i| {
                idx.* = i;
            }

            return res;
        }

        pub fn allocBuf(self: *@This()) ?usize {
            if (self.stack_head <= 0) {
                return null;
            }

            const idx = self.idx_stack[self.stack_head];
            self.stack_head -= 1;
            return idx;
        }

        pub fn releaseBuf(self: *@This(), idx: usize) void {
            self.idx_stack[self.stack_head] = idx;
            self.stack_head += 1;
        }

        pub fn deinit(self: *@This()) void {
            self.buf_alloc.destroy(self.buffers);
        }
    };
}
