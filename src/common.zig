const std = @import("std");

const uring = @import("uring.zig");

pub const UserdataOp = enum(u16) {
    Accept,
    Read,
};

pub const Userdata = packed struct {
    op: UserdataOp,
    d: u16,
    fd: i32,
};

pub const Client = struct {
    fd: i32,
    read_buf: [4096]u8,
    read_buf_tail: usize,
    write_buf: [4096]u8,
    write_buf_tail: usize,
    addr: std.os.linux.sockaddr,
};

pub const ClientManager = struct {
    lookup: std.ArrayList(?*Client),
    lookup_alloc: std.mem.Allocator,
    client_alloc: std.mem.Allocator,

    pub fn init(
        initCap: usize,
        lookup_alloc: std.mem.Allocator,
        client_alloc: std.mem.Allocator,
    ) !ClientManager {
        return ClientManager{
            .lookup = try std.ArrayList(?*Client).initCapacity(lookup_alloc, initCap),
            .lookup_alloc = lookup_alloc,
            .client_alloc = client_alloc,
        };
    }

    pub fn deinit(self: *ClientManager) void {
        self.lookup.deinit(self.lookup_alloc);
    }

    pub fn get(self: *ClientManager, fd: i32) ?*Client {
        if (fd < 0) {
            return null;
        }

        const ufd: usize = @intCast(fd);
        if (ufd >= self.lookup.items.len) {
            return null;
        }

        return self.lookup.items[ufd];
    }

    pub fn add(self: *ClientManager, fd: i32) !*Client {
        const ufd: usize = @intCast(fd);
        if (ufd >= self.lookup.items.len) {
            try self.lookup.appendNTimes(self.lookup_alloc, null, ufd - self.lookup.items.len + 1);
        }

        const client = try self.client_alloc.create(Client);
        client.fd = fd;
        client.read_buf_tail = 0;
        client.write_buf_tail = 0;
        self.lookup.items[ufd] = client;

        return client;
    }

    pub fn remove(self: *ClientManager, fd: i32) void {
        if (fd < 0) {
            return;
        }

        const ufd: usize = @intCast(fd);
        if (self.lookup.items.len < fd) {
            return;
        }

        if (self.lookup.items[ufd]) |conn| {
            self.client_alloc.destroy(conn);
            self.lookup.items[ufd] = null;
        }
    }
};

pub const Context = struct {
    client_manager: ClientManager,
    ring: uring.Ring,
    server_fd: i32,
};
