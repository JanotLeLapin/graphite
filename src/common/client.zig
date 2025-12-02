const std = @import("std");

const Uuid = @import("mod.zig").Uuid;

pub const ClientState = enum(u8) {
    Handshake = 0,
    Status = 1,
    Login = 2,
};

pub const Client = struct {
    fd: i32,
    state: ClientState,
    read_buf: [4096]u8,
    read_buf_tail: usize,
    addr: std.os.linux.sockaddr,
    username_buf: [64]u8,
    username: std.ArrayListUnmanaged(u8),
    uuid: Uuid,
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
        for (self.lookup.items) |item| {
            if (item) |client| {
                self.client_alloc.destroy(client);
            }
        }
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
