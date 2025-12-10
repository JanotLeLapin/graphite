const std = @import("std");

const zcs = @import("zcs");

const Uuid = @import("root.zig").Uuid;

pub const Client = struct {
    fd: i32,
    e: zcs.Entity,
    addr: std.os.linux.sockaddr,
    username_buf: [64]u8,
    username: std.ArrayListUnmanaged(u8),
    uuid: Uuid,
};

pub fn ClientSlot(comptime T: type) type {
    return struct {
        client: ?*T,
        generation: u64,
    };
}

pub fn ClientManager(comptime T: type) type {
    return struct {
        lookup: std.ArrayList(ClientSlot(T)),
        lookup_alloc: std.mem.Allocator,
        client_alloc: std.mem.Allocator,
        global_generation: u64,
        count: u64,

        pub fn init(
            initCap: usize,
            lookup_alloc: std.mem.Allocator,
            client_alloc: std.mem.Allocator,
        ) !@This() {
            return @This(){
                .lookup = try std.ArrayList(ClientSlot(T)).initCapacity(lookup_alloc, initCap),
                .lookup_alloc = lookup_alloc,
                .client_alloc = client_alloc,
                .global_generation = 0,
                .count = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            for (self.lookup.items) |item| {
                if (item.client) |client| {
                    self.client_alloc.destroy(client);
                }
            }
            self.lookup.deinit(self.lookup_alloc);
        }

        pub fn get(self: *@This(), fd: i32) ?*T {
            if (fd < 0) {
                return null;
            }

            const ufd: usize = @intCast(fd);
            if (ufd >= self.lookup.items.len) {
                return null;
            }

            return self.lookup.items[ufd].client;
        }

        pub fn add(self: *@This(), fd: i32) !*T {
            const ufd: usize = @intCast(fd);
            if (ufd >= self.lookup.items.len) {
                try self.lookup.appendNTimes(self.lookup_alloc, .{
                    .client = null,
                    .generation = 0,
                }, ufd - self.lookup.items.len + 1);
            }

            const client = try self.client_alloc.create(T);
            self.lookup.items[ufd] = .{
                .client = client,
                .generation = self.global_generation,
            };

            self.global_generation += 1;
            self.count += 1;

            return client;
        }

        pub fn remove(self: *@This(), fd: i32) void {
            if (fd < 0) {
                return;
            }

            const ufd: usize = @intCast(fd);
            if (self.lookup.items.len < fd) {
                return;
            }

            if (self.lookup.items[ufd].client) |conn| {
                self.client_alloc.destroy(conn);
                self.lookup.items[ufd].client = null;
                self.count -= 1;
            }
        }
    };
}
