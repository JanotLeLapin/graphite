const std = @import("std");

const client = @import("client.zig");
const uring = @import("uring.zig");

pub const BufferError = error{ZeroBroadcast};

pub const BufferType = union(enum) {
    Broadcast,
    Oneshot,
};

pub fn Buffer(comptime size: comptime_int) type {
    return struct {
        t: BufferType,
        idx: usize,
        data: [size]u8,
        size: usize,

        ref_count: usize,

        pub fn prepareOneshot(
            self: *@This(),
            ring: *uring.Ring,
            fd: i32,
            len: usize,
        ) !void {
            self.t = .Oneshot;
            self.size = len;
            self.ref_count = 1;

            var sqe = try ring.getSqe();
            sqe.prep_write(fd, self.data[0..len], 0);
            sqe.user_data = @bitCast(uring.Userdata{ .op = .Write, .d = @intCast(self.idx), .fd = fd });
        }

        pub fn prepareBroadcast(
            self: *@This(),
            ring: *uring.Ring,
            clients: []client.ClientSlot,
            len: usize,
        ) !void {
            self.t = .Broadcast;
            self.size = len;
            self.ref_count = 0;

            for (clients) |slot| {
                if (slot.client) |c| {
                    var sqe = ring.getSqe() catch break;
                    sqe.prep_write(c.fd, self.data[0..len], 0);
                    sqe.user_data = @bitCast(uring.Userdata{ .op = .Write, .d = @intCast(self.idx), .fd = c.fd });
                    self.ref_count += 1;
                }
            }

            if (self.ref_count == 0) return BufferError.ZeroBroadcast;
        }
    };
}

pub fn BufferPool(comptime buf_size: comptime_int, comptime cap: comptime_int) type {
    const B = Buffer(buf_size);

    return struct {
        idx_stack: [cap]usize,
        busy_count: usize,
        buffers: []B,
        buf_alloc: std.mem.Allocator,

        pub fn init(buf_alloc: std.mem.Allocator) !@This() {
            var res = @This(){
                .idx_stack = undefined,
                .busy_count = 0,
                .buffers = try buf_alloc.alloc(B, cap),
                .buf_alloc = buf_alloc,
            };

            for (&res.idx_stack, res.buffers, 0..) |*idx, *b, i| {
                idx.* = i;
                b.idx = i;
            }

            return res;
        }

        pub fn allocBuf(self: *@This()) ?*B {
            if (self.busy_count >= cap) {
                return null;
            }

            const idx = self.idx_stack[self.busy_count];
            self.busy_count += 1;
            return &self.buffers[idx];
        }

        pub fn releaseBuf(self: *@This(), idx: usize) void {
            self.busy_count -= 1;
            self.idx_stack[self.busy_count] = idx;
        }

        pub fn deinit(self: *@This()) void {
            self.buf_alloc.free(self.buffers);
        }
    };
}
