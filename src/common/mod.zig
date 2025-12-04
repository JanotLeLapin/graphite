const std = @import("std");

const Modules = @import("root").Modules;

pub const buffer = @import("buffer.zig");
pub const chat = @import("chat.zig");
pub const client = @import("client.zig");
pub const uring = @import("uring.zig");

pub const ModuleRegistry = struct {
    instances: std.meta.Tuple(&Modules),

    pub fn init(alloc: std.mem.Allocator) !ModuleRegistry {
        var self: ModuleRegistry = undefined;

        inline for (Modules, 0..) |ModuleType, i| {
            self.instances[i] = try ModuleType.init(alloc);
        }
        return self;
    }

    pub fn deinit(self: *ModuleRegistry) void {
        inline for (Modules) |ModuleType| {
            var instance = self.get(ModuleType);
            instance.deinit();
        }
    }

    pub fn get(self: *ModuleRegistry, comptime T: type) *T {
        const index = comptime findIndex(T);
        return &self.instances[index];
    }

    pub fn findIndex(comptime T: type) usize {
        inline for (Modules, 0..) |ModuleType, i| {
            if (ModuleType == T) return i;
        }
        @compileError("Unrecognized module " ++ @typeName(T));
    }
};

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
        _ = std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{
            std.fmt.bytesToHex(self.bytes[0..4], .lower),
            std.fmt.bytesToHex(self.bytes[4..6], .lower),
            std.fmt.bytesToHex(self.bytes[6..8], .lower),
            std.fmt.bytesToHex(self.bytes[8..10], .lower),
            std.fmt.bytesToHex(self.bytes[10..16], .lower),
        }) catch unreachable;
    }
};

pub const Context = struct {
    client_manager: *client.ClientManager,
    ring: *uring.Ring,
    buffer_pool: *buffer.BufferPool(4096),
    module_registry: ModuleRegistry,
};
