const std = @import("std");

const root = @import("root.zig");
const Buffer = root.buffer.Buffer;

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

pub const RingTask = union(enum) {
    accept: struct {
        sfd: i32,
        addr: *std.os.linux.sockaddr,
        addr_len: *std.os.linux.socklen_t,
    },
    timer: struct {
        tfd: i32,
        tinfo: *u64,
    },
    read: struct {
        cfd: i32,
        buffer: []u8,
    },
    oneshot: struct {
        buffer: *Buffer,
        cfd: i32,
    },
    broadcast: struct {
        buffer: *Buffer,
        cursor: usize,
        max_gen: u64,
    },

    pub fn pump(
        self: *RingTask,
        ring: *Ring,
        clients: []root.client.ClientSlot,
    ) !bool {
        switch (self.*) {
            .accept => |*a| {
                var sqe = ring.getSqe() catch return false;
                sqe.prep_accept(a.sfd, a.addr, a.addr_len, 0);
                sqe.user_data = @bitCast(Userdata{ .op = .accept, .d = 0, .fd = 0 });
                return true;
            },
            .timer => |*t| {
                var sqe = ring.getSqe() catch return false;
                sqe.prep_read(t.tfd, @ptrCast(t.tinfo), 0);
                sqe.user_data = @bitCast(Userdata{ .op = .timer, .d = 0, .fd = 0 });
                return true;
            },
            .read => |*r| {
                var sqe = ring.getSqe() catch return false;
                sqe.prep_read(r.cfd, r.buffer, 0);
                sqe.user_data = @bitCast(Userdata{ .op = .read, .d = 0, .fd = r.cfd });
                return true;
            },
            .oneshot => |*o| {
                var sqe = ring.getSqe() catch return false;
                sqe.prep_send_zc(o.cfd, o.buffer.ptr[0..o.buffer.size], 0, 0);
                sqe.user_data = @bitCast(Userdata{ .op = .write, .d = @bitCast(o.buffer.idx), .fd = o.cfd });
                return true;
            },
            .broadcast => |*b| {
                while (b.cursor < clients.len) : (b.cursor += 1) {
                    const slot = clients[b.cursor];

                    if (slot.generation > b.max_gen) {
                        continue;
                    }

                    if (slot.client) |c| {
                        var sqe = ring.getSqe() catch return false;
                        sqe.prep_send_zc(c.fd, b.buffer.ptr[0..b.buffer.size], 0, 0);
                        sqe.user_data = @bitCast(Userdata{ .op = .write, .d = @bitCast(b.buffer.idx), .fd = c.fd });
                        b.buffer.ref_count += 1;
                    }
                }
                b.buffer.ref_count -= 1;
                return true;
            },
        }
    }
};

pub const RingTaskNode = struct {
    node: std.DoublyLinkedList.Node,
    data: RingTask,
};

pub const RingError = error{
    SubmissionQueueFull,
    CompletionQueueEmpty,
    ZeroBroadcast,
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

    tasks: std.DoublyLinkedList,
    task_alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, entries: u32) !Ring {
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
            .tasks = .{ .first = null, .last = null },
            .task_alloc = alloc,
        };
    }

    pub fn getSqe(self: *Ring) !*std.os.linux.io_uring_sqe {
        const tail = self.sq_tail_local;
        const head = self.sq_head.load(.acquire);
        const mask = self.sq_mask.*;

        if (tail -% head >= self.sq_entries.*) {
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

    pub fn insertTask(self: *Ring, task: RingTask) !void {
        const node = try self.task_alloc.create(RingTaskNode);
        node.data = task;
        node.node.next = null;
        self.tasks.append(&node.node);
    }

    pub fn prepareAccept(
        self: *Ring,
        fd: i32,
        addr: *std.os.linux.sockaddr,
        addr_len: *std.os.linux.socklen_t,
    ) !void {
        const sqe = self.getSqe() catch {
            try self.insertTask(.{ .accept = .{
                .sfd = fd,
                .addr = addr,
                .addr_len = addr_len,
            } });
            return;
        };
        sqe.prep_accept(fd, addr, addr_len, 0);
        sqe.user_data = @bitCast(Userdata{ .op = .accept, .d = 0, .fd = 0 });
    }

    pub fn prepareRead(
        self: *Ring,
        fd: i32,
        buffer: []u8,
    ) !void {
        const sqe = self.getSqe() catch {
            try self.insertTask(.{ .read = .{
                .cfd = fd,
                .buffer = buffer,
            } });
            return;
        };
        sqe.prep_read(fd, buffer, 0);
        sqe.user_data = @bitCast(Userdata{ .op = .read, .d = 0, .fd = fd });
    }

    pub fn prepareTimer(
        self: *Ring,
        fd: i32,
        tinfo: *u64,
    ) !void {
        const sqe = self.getSqe() catch {
            try self.insertTask(.{ .timer = .{
                .tfd = fd,
                .tinfo = tinfo,
            } });
            return;
        };
        sqe.prep_read(fd, @ptrCast(tinfo), 0);
        sqe.user_data = @bitCast(Userdata{ .op = .timer, .d = 0, .fd = 0 });
    }

    pub fn prepareOneshot(
        self: *Ring,
        fd: i32,
        b: *Buffer,
        size: usize,
    ) !void {
        b.t = .oneshot;
        b.size = size;
        b.ref_count = 1;

        var sqe = self.getSqe() catch {
            try self.insertTask(.{ .oneshot = .{
                .buffer = b,
                .cfd = fd,
            } });
            return;
        };
        sqe.prep_send_zc(fd, b.ptr[0..size], 0, 0);
        sqe.user_data = @bitCast(Userdata{ .op = .write, .d = @bitCast(b.idx), .fd = fd });
    }

    pub fn prepareBroadcast(
        self: *Ring,
        ctx: *root.Context,
        b: *Buffer,
        size: usize,
    ) !void {
        b.t = .broadcast;
        b.size = size;
        b.ref_count = 0;

        for (ctx.client_manager.lookup.items, 0..) |slot, i| {
            if (slot.client) |c| {
                var sqe = self.getSqe() catch {
                    b.ref_count += 1;
                    try self.insertTask(.{ .broadcast = .{
                        .buffer = b,
                        .cursor = i,
                        .max_gen = ctx.client_manager.global_generation,
                    } });
                    return;
                };
                sqe.prep_send_zc(c.fd, b.ptr[0..size], 0, 0);
                sqe.user_data = @bitCast(Userdata{ .op = .write, .d = @bitCast(b.idx), .fd = c.fd });
                b.ref_count += 1;
            }
        }
        if (b.ref_count == 0) return RingError.ZeroBroadcast;
    }

    pub fn pump(self: *Ring, ctx: *root.Context) !void {
        while (self.tasks.first) |node| {
            const task_node: *RingTaskNode = @fieldParentPtr("node", node);
            const finished = try task_node.data.pump(self, ctx.client_manager.lookup.items);

            if (finished) {
                _ = self.tasks.popFirst();
                self.task_alloc.destroy(task_node);
            } else {
                break;
            }
        }
    }

    pub fn deinit(self: *Ring) void {
        std.posix.close(self.fd);
        std.posix.munmap(self.sqes_mmap);
        std.posix.munmap(self.sq_mmap);

        while (self.tasks.pop()) |node| {
            const task_node: *RingTaskNode = @fieldParentPtr("node", node);
            self.task_alloc.destroy(task_node);
        }
    }
};
