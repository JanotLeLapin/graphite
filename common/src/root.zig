const std = @import("std");

pub const zcs = @import("zcs");
const SpscQueue = @import("spsc_queue").SpscQueue;

pub const buffer = @import("buffer.zig");
pub const chat = @import("chat.zig");
pub const chunk = @import("chunk.zig");
pub const client = @import("client.zig");
pub const ecs = @import("ecs.zig");
pub const scheduler = @import("scheduler.zig");

pub const ServerMessage = union(enum) {
    tick,
    write_result: buffer.BufferIndex,
    write_error: buffer.BufferIndex,

    status_request: i32,
    status_ping: struct {
        fd: i32,
        payload: u64,
    },
    player_join: struct {
        fd: i32,
        username: [64]u8,
        username_len: usize,
        addr: std.os.linux.sockaddr,
        location: ecs.Location,
    },
    player_move: struct {
        fd: i32,
        d: ecs.Location,
    },
    player_chat: struct {
        fd: i32,
        message: [128]u8,
        message_len: usize,
    },
    player_quit: i32,
    stop,
};

pub const GameMessage = union(enum) {
    prepare_oneshot: struct {
        fd: i32,
        b: *buffer.Buffer,
        size: usize,
    },
    prepare_broadcast: struct {
        b: *buffer.Buffer,
        size: usize,
    },
};

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
    client_manager: *client.ClientManager(client.Client),
    buffer_pools: *buffer.BufferPools,
    scheduler: *scheduler.Scheduler,
    module_registry: *anyopaque,
    tx: *SpscQueue(GameMessage, true),
    efd: i32,

    pub fn prepareOneshot(
        self: *Context,
        fd: i32,
        b: *buffer.Buffer,
        size: usize,
    ) void {
        self.tx.push(.{ .prepare_oneshot = .{
            .fd = fd,
            .b = b,
            .size = size,
        } });

        const val: u64 = 0;
        _ = std.os.linux.write(self.efd, std.mem.asBytes(&val), 8);
    }

    pub fn prepareBroadcast(
        self: *Context,
        b: *buffer.Buffer,
        size: usize,
    ) void {
        self.tx.push(.{ .prepare_broadcast = .{
            .b = b,
            .size = size,
        } });

        const val: u64 = 0;
        _ = std.os.linux.write(self.efd, std.mem.asBytes(&val), 8);
    }

    pub fn getModuleRegistry(self: *const Context, comptime T: type) *T {
        return @ptrCast(@alignCast(self.module_registry));
    }
};
