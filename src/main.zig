const std = @import("std");

const graphite = @import("graphite");
const uring = @import("uring.zig");

const PORT = 25565;
const ADDRESS = "127.0.0.1";

const URING_QUEUE_ENTRIES = 4096;

const UserdataOp = enum(u16) {
    Accept,
    Read,
};

const Userdata = packed struct {
    op: UserdataOp,
    d: u16,
    fd: i32,
};

const Client = struct {
    fd: i32,
    read_buf: [4096]u8,
    read_buf_tail: usize,
    write_buf: [4096]u8,
    write_buf_tail: usize,
    addr: std.os.linux.sockaddr,
};

const ClientManager = struct {
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var client_manager = try ClientManager.init(8, gpa.allocator(), gpa.allocator());
    defer client_manager.deinit();

    const serverfd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(serverfd);

    const addr_in = try std.net.Address.parseIp4(ADDRESS, PORT);

    try std.posix.setsockopt(serverfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(serverfd, &addr_in.any, addr_in.getOsSockLen());
    try std.posix.listen(serverfd, 128);

    std.log.info("server listening on port {d}.", .{PORT});

    var ring = try uring.Ring.init(URING_QUEUE_ENTRIES);
    defer ring.deinit();

    std.log.info("ring initialized: {d}.", .{ring.fd});

    var addr: std.os.linux.sockaddr = undefined;
    var addr_len: std.os.linux.socklen_t = @sizeOf(@TypeOf(addr));

    {
        const sqe = try ring.getSqe();
        sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Accept, .d = 0, .fd = 0 });
        sqe.prep_accept(serverfd, &addr, &addr_len, 0);
    }

    _ = try ring.submit();
    std.debug.print("submitted to SQE\n", .{});

    while (true) {
        const cqe = try ring.waitCqe();
        const ud: Userdata = @bitCast(cqe.user_data);
        switch (ud.op) {
            .Accept => {
                const cfd = cqe.res;
                std.debug.print("new client: {d}\n", .{cfd});

                var client = try client_manager.add(cfd);
                client.addr = addr;

                {
                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.ACCEPT;
                    sqe.prep_accept(serverfd, &addr, &addr_len, 0);
                    sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Accept, .d = 0, .fd = cfd });
                }

                {
                    const sqe = try ring.getSqe();
                    sqe.opcode = std.os.linux.IORING_OP.READ;
                    sqe.prep_read(cfd, &client_manager.get(cfd).?.read_buf, 0);
                    sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Read, .d = 0, .fd = cfd });
                }

                _ = try ring.submit();
            },
            .Read => {
                const cfd = ud.fd;
                const bytes: usize = @intCast(cqe.res);

                if (0 == bytes) {
                    client_manager.remove(cfd);
                    std.debug.print("closed client: {d}\n", .{cfd});
                    continue;
                }

                const client = client_manager.get(cfd).?;
                client.read_buf_tail += bytes;

                std.debug.print("read {d} bytes from client {d}: {any}\n", .{ bytes, cfd, client_manager.get(cfd).?.read_buf[0..client.read_buf_tail] });

                const sqe = try ring.getSqe();
                sqe.opcode = std.os.linux.IORING_OP.READ;
                sqe.prep_read(cfd, client.read_buf[client.read_buf_tail..], 0);
                sqe.user_data = @bitCast(Userdata{ .op = UserdataOp.Read, .d = 0, .fd = cfd });

                _ = try ring.submit();
            },
        }
    }
}
