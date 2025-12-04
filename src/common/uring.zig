const std = @import("std");

pub const UserdataOp = enum(u4) {
    accept,
    sigint,
    timer,
    read,
    write,
};

pub const Userdata = packed struct {
    op: UserdataOp,
    d: u28,
    fd: i32,
};

pub const RingError = error{
    SubmissionQueueFull,
    CompletionQueueEmpty,
};

pub const Ring = struct {
    fd: i32,
    sq_mmap: []align(std.heap.page_size_max) u8,
    cq_mmap: []align(std.heap.page_size_max) u8,
    sqes_mmap: []align(std.heap.page_size_max) u8,

    sq_head: *std.atomic.Value(u32),
    sq_tail: *std.atomic.Value(u32),
    sq_tail_local: u32,
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
            .sq_tail_local = @as(*u32, @ptrCast(@alignCast(sq_ptr.ptr + params.sq_off.tail))).*,
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

    pub fn getSqe(self: *Ring) !*std.os.linux.io_uring_sqe {
        const tail = self.sq_tail_local;
        const head = self.sq_head.load(.acquire);
        const mask = self.sq_mask.*;

        if (tail -% head > self.sq_entries.*) {
            return RingError.SubmissionQueueFull;
        }

        const index = tail & mask;
        const sqes: [*]std.os.linux.io_uring_sqe = @ptrCast(@alignCast(self.sqes_mmap.ptr));
        const sqe = &sqes[index];

        sqe.* = std.mem.zeroes(std.os.linux.io_uring_sqe);
        self.sq_array[index] = index;
        self.sq_tail_local = tail +% 1;

        return sqe;
    }

    pub fn submit(self: *Ring) !usize {
        const tail = self.sq_tail.load(.monotonic);
        const to_submit = self.sq_tail_local -% tail;

        if (to_submit == 0) {
            return 0;
        }

        self.sq_tail.store(self.sq_tail_local, .release);

        return std.os.linux.io_uring_enter(self.fd, to_submit, 0, 0, null);
    }

    pub fn peekCqe(self: *Ring) ?std.os.linux.io_uring_cqe {
        const head = self.cq_head.load(.monotonic);
        const tail = self.cq_tail.load(.acquire);

        if (head == tail) return null;

        const index = head & self.cq_mask.*;
        const cqe = self.cqes[index];

        self.cq_head.store(head +% 1, .release);

        return cqe;
    }

    pub fn waitCqe(self: *Ring) !std.os.linux.io_uring_cqe {
        const cqe = self.peekCqe();
        if (cqe) |c| return c;

        _ = std.os.linux.io_uring_enter(self.fd, 0, 1, std.os.linux.IORING_ENTER_GETEVENTS, null);

        return self.peekCqe() orelse RingError.CompletionQueueEmpty;
    }

    pub fn deinit(self: *Ring) void {
        std.posix.close(self.fd);
        std.posix.munmap(self.sqes_mmap);
        std.posix.munmap(self.sq_mmap);
    }
};
