const std = @import("std");

pub const buffer = @import("buffer.zig");
pub const client = @import("client.zig");
pub const uring = @import("uring.zig");

pub const Uuid = struct {
    bytes: [16]u8,

    pub fn random(rand: std.Random) Uuid {
        var uuid = Uuid{ .bytes = undefined };
        rand.bytes(uuid.bytes[0..]);
        uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x40;
        uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;
        return uuid;
    }

    pub fn stringify(self: Uuid, buf: *[36]u8) void {
        _ = std.fmt.bufPrint(buf, "{x}-{x}-{x}-{x}-{x}", .{
            std.mem.readInt(u32, self.bytes[0..4], .little),
            std.mem.readInt(u16, self.bytes[4..6], .little),
            std.mem.readInt(u16, self.bytes[6..8], .little),
            std.mem.readInt(u16, self.bytes[8..10], .little),
            std.mem.readInt(u48, self.bytes[10..16], .little),
        }) catch unreachable;
    }
};

pub const Context = struct {
    client_manager: client.ClientManager,
    ring: *uring.Ring,
    buffer_pool: *buffer.BufferPool(4096, 64),
};
