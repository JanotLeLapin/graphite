const std = @import("std");

pub const Ring = struct {
    fd: i32,
    sq_mmap: []align(std.heap.page_size_max) u8,
    cq_mmap: []align(std.heap.page_size_max) u8,
    sqes_mmap: []align(std.heap.page_size_max) u8,

    sq_head: *std.atomic.Value(u32),
    sq_tail: *std.atomic.Value(u32),
    sq_mask: *const u32,
    sq_entries: *const u32,
    sq_flags: *const u32,
    sq_array: [*]u32,

    cq_head: *std.atomic.Value(u32),
    cq_tail: *std.atomic.Value(u32),
    cq_mask: *const u32,
    cq_entries: *const u32,
    cqes: [*]std.os.linux.io_uring_cqe,

    pub fn init(entries: u32) !Ring {
        var params = std.mem.zeroes(std.os.linux.io_uring_params);

        const fd: i32 = @bitCast(@as(u32, @truncate(std.os.linux.io_uring_setup(entries, &params))));
        errdefer std.posix.close(fd);

        const sq_sz = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const cq_sz = params.cq_off.cqes + params.cq_entries * @sizeOf(std.os.linux.io_uring_cqe);
        const map_sz = @max(sq_sz, cq_sz);

        const sq_ptr = try std.posix.mmap(
            null,
            map_sz,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            std.os.linux.IORING_OFF_SQ_RING,
        );
        errdefer std.posix.munmap(sq_ptr);

        const sqes_sz = params.sq_entries * @sizeOf(std.os.linux.io_uring_sqe);
        const sqes_ptr = try std.posix.mmap(
            null,
            sqes_sz,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            std.os.linux.IORING_OFF_SQES,
        );
        errdefer std.posix.munmap(sqes_ptr);

        return Ring{
            .fd = fd,
            .sq_mmap = sq_ptr,
            .cq_mmap = sq_ptr,
            .sqes_mmap = sqes_ptr,
            .sq_head = @ptrCast(@alignCast(sq_ptr.ptr + params.sq_off.head)),
            .sq_tail = @ptrCast(@alignCast(sq_ptr.ptr + params.sq_off.tail)),
            .sq_mask = @ptrCast(@alignCast(sq_ptr.ptr + params.sq_off.ring_mask)),
            .sq_entries = @ptrCast(@alignCast(sq_ptr.ptr + params.sq_off.ring_entries)),
            .sq_flags = @ptrCast(@alignCast(sq_ptr.ptr + params.sq_off.flags)),
            .sq_array = @ptrCast(@alignCast(sq_ptr.ptr + params.sq_off.array)),
            .cq_head = @ptrCast(@alignCast(sq_ptr.ptr + params.cq_off.head)),
            .cq_tail = @ptrCast(@alignCast(sq_ptr.ptr + params.cq_off.tail)),
            .cq_mask = @ptrCast(@alignCast(sq_ptr.ptr + params.cq_off.ring_mask)),
            .cq_entries = @ptrCast(@alignCast(sq_ptr.ptr + params.cq_off.ring_entries)),
            .cqes = @ptrCast(@alignCast(sq_ptr.ptr + params.cq_off.cqes)),
        };
    }

    pub fn deinit(self: *Ring) void {
        std.posix.close(self.fd);
        std.posix.munmap(self.sqes_mmap);
        std.posix.munmap(self.sq_mmap);
    }
};
