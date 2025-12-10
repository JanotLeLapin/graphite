const std = @import("std");

pub const zcs = @import("zcs");

pub const buffer = @import("buffer.zig");
pub const chat = @import("chat.zig");
pub const chunk = @import("chunk.zig");
pub const client = @import("client.zig");
pub const ecs = @import("ecs.zig");
pub const scheduler = @import("scheduler.zig");
pub const uring = @import("uring.zig");

pub const ServerMessage = union(enum) {
    player_join: i32,
};
pub const GameMessage = union(enum) {};

pub fn ModuleRegistry(comptime Modules: anytype) type {
    return struct {
        instances: std.meta.Tuple(&Modules),

        pub fn init(alloc: std.mem.Allocator) !@This() {
            var self: @This() = undefined;

            inline for (Modules, 0..) |ModuleType, i| {
                self.instances[i] = try ModuleType.init(alloc);
            }
            return self;
        }

        pub fn deinit(self: *@This()) void {
            inline for (Modules) |ModuleType| {
                var instance = self.get(ModuleType);
                instance.deinit();
            }
        }

        pub fn get(self: *@This(), comptime T: type) *T {
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
}

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

/// Encodes a MIDI pitch value to a Minecraft client-bound note pitch value.
/// The MIDI note is clamped between 42 and 66.
pub fn pitchFromMidi(midi: u8) u8 {
    const clamped: f64 = @floatFromInt(@min(@max(midi, 42), 66));
    return @intFromFloat(63 * @exp2((clamped - 54) / 12));
}

pub const Context = struct {
    entities: *zcs.Entities,
    zcs_alloc: std.mem.Allocator,
    client_manager: *client.ClientManager,
    ring: *uring.Ring,
    buffer_pools: *buffer.BufferPools,
    scheduler: *scheduler.Scheduler,
    module_registry: *anyopaque,

    pub fn addClient(self: *Context, fd: i32) !*client.Client {
        var cb = try zcs.CmdBuf.init(.{ .name = null, .gpa = self.zcs_alloc, .es = self.entities });
        defer cb.deinit(self.zcs_alloc, self.entities);

        const e = zcs.Entity.reserve(&cb);
        _ = e.add(&cb, ecs.Client, .{ .fd = fd });

        zcs.CmdBuf.Exec.immediate(self.entities, &cb);
        return self.client_manager.add(fd, e);
    }

    pub fn removeClient(self: *Context, fd: i32) !void {
        const c = self.client_manager.get(fd) orelse return;

        var cb = try zcs.CmdBuf.init(.{ .name = null, .gpa = self.zcs_alloc, .es = self.entities });
        defer cb.deinit(self.zcs_alloc, self.entities);

        c.e.destroy(&cb);

        zcs.CmdBuf.Exec.immediate(self.entities, &cb);

        self.client_manager.remove(fd);
    }

    pub fn getModuleRegistry(self: *const Context, comptime T: type) *T {
        return @ptrCast(@alignCast(self.module_registry));
    }
};
