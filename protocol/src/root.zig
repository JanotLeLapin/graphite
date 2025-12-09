// This file heavily relies on wiki.vg

const std = @import("std");

pub const common = @import("graphite-common");

pub const types = @import("types/mod.zig");

pub const GamemodeType = enum(u8) {
    survival = 0,
    creative = 1,
    adventure = 2,
    spectator = 3,
};

pub fn Gamemode(comptime Gt: GamemodeType, comptime hardcore: bool) u8 {
    return @intFromEnum(Gt) | (@as(u8, @intCast(@intFromBool(hardcore))) << 7);
}

pub const Dimension = enum(i8) {
    nether = -1,
    overworld = 0,
    end = 1,
};

pub const Difficulty = enum(u8) {
    peaceful = 0,
    easy = 1,
    normal = 2,
    hard = 3,
};

pub const EncodingError = error{
    OutOfBounds,
    SubImplFailed,
};

pub fn decodeValue(comptime T: anytype, buf: []const u8) !struct { value: T, len: usize } {
    switch (@typeInfo(T)) {
        .int, .float => {
            const size = @sizeOf(T);
            if (buf.len < size) {
                return EncodingError.OutOfBounds;
            }

            const raw = std.mem.readInt(std.meta.Int(.unsigned, size * 8), buf[0..size], .big);
            return .{ .value = @bitCast(raw), .len = size };
        },
        .bool => {
            return .{ .value = buf[0] > 0, .len = 1 };
        },
        .pointer => |p| {
            if (p.size != .slice or !p.is_const or p.child != u8) {
                @compileError("invalid type: " ++ @typeName(T));
            }

            const string = types.String.decode(buf) catch return EncodingError.SubImplFailed;
            return .{ .value = string.value, .len = string.len };
        },
        .@"struct" => {
            const val = T.decode(buf) catch return EncodingError.SubImplFailed;
            return .{ .value = T{ .value = val.value }, .len = val.len };
        },
        else => @compileError("invalid type: " ++ @typeName(T)),
    }
}

pub fn encodeValue(comptime T: anytype, v: T, buf: []u8) !usize {
    switch (@typeInfo(T)) {
        .int, .float => {
            const size = @sizeOf(T);
            if (buf.len < size) {
                return EncodingError.OutOfBounds;
            }

            const raw: std.meta.Int(.unsigned, size * 8) = @bitCast(v);
            buf[0..size].* = @bitCast(@byteSwap(raw));
            return size;
        },
        .bool => {
            buf[0] = @intFromBool(v);
            return 1;
        },
        .@"enum" => {
            const TagType = @typeInfo(T).@"enum".tag_type;
            const size = @sizeOf(TagType);
            if (buf.len < size) {
                return EncodingError.OutOfBounds;
            }

            std.mem.writeInt(TagType, buf[0..size], @intFromEnum(v), .big);
            return size;
        },
        .pointer => |p| {
            if (p.size != .slice or !p.is_const or p.child != u8) {
                @compileError("invalid type: " ++ @typeName(T));
            }

            const size = types.String.encode(v, buf) catch return EncodingError.SubImplFailed;
            return size;
        },
        .@"struct" => {
            const size = T.encode(v.value, buf) catch return EncodingError.SubImplFailed;
            return size;
        },
        else => @compileError("invalid type: " ++ @typeName(T)),
    }
}

fn genDecodeBasic(comptime T: anytype) fn ([]const u8) EncodingError!T {
    return struct {
        fn decodeFn(buf: []const u8) !T {
            var res: T = undefined;
            var offset: usize = 0;

            inline for (std.meta.fields(T)) |field| {
                if (offset >= buf.len) {
                    return EncodingError.OutOfBounds;
                }

                const rem = buf[offset..];
                const FieldType = field.type;

                const decoded = try decodeValue(FieldType, rem);
                @field(res, field.name) = decoded.value;
                offset += decoded.len;
            }

            return res;
        }
    }.decodeFn;
}

fn genEncodeBasic(
    comptime T: anytype,
    comptime packet_id: comptime_int,
) fn (*const T, []u8) EncodingError!usize {
    return struct {
        fn encodeFn(self: *const T, buf: []u8) !usize {
            var offset: usize = 5;
            offset += types.VarInt.encode(packet_id, buf[offset..]) catch return EncodingError.OutOfBounds;

            inline for (std.meta.fields(T)) |field| {
                if (offset >= buf.len) {
                    return EncodingError.OutOfBounds;
                }

                const rem = buf[offset..];
                const FieldType = field.type;

                offset += try encodeValue(FieldType, @field(self, field.name), rem);
            }

            const size = types.VarInt.encode(@intCast(offset - 5), buf) catch return EncodingError.OutOfBounds;
            @memmove(buf[size .. size + offset], buf[5 .. 5 + offset]);

            return size + offset - 5;
        }
    }.encodeFn;
}

pub const ServerHandshake = struct {
    protocol_version: types.VarInt,
    server_address: []const u8,
    server_port: u16,
    next_state: u8,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerStatusPing = struct {
    payload: u64,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerLoginStart = struct {
    username: []const u8,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayChatMessage = struct {
    message: []const u8,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayPlayer = struct {
    on_ground: u8,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayPlayerPosition = struct {
    x: f64,
    y: f64,
    z: f64,
    on_ground: u8,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayPlayerLook = struct {
    yaw: f32,
    pitch: f32,
    on_ground: u8,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayPlayerPositionAndLook = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    on_ground: u8,

    pub fn decode(buf: []const u8) !@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerBoundPacketError = error{
    BadPacketId,
};

pub const ServerBoundPacket = union(enum) {
    handshake: ServerHandshake,
    status_request,
    status_ping: ServerStatusPing,
    login_start: ServerLoginStart,
    play_chat_message: ServerPlayChatMessage,
    play_player: ServerPlayPlayer,
    play_player_position: ServerPlayPlayerPosition,
    play_player_look: ServerPlayPlayerLook,
    play_player_position_and_look: ServerPlayPlayerPositionAndLook,

    pub fn decode(
        state: common.client.ClientState,
        packet_id: i32,
        buf: []const u8,
    ) !ServerBoundPacket {
        return switch (state) {
            .handshake => .{ .handshake = try ServerHandshake.decode(buf) },
            .status => switch (packet_id) {
                0x00 => .{ .status_request = undefined },
                0x01 => .{ .status_ping = try ServerStatusPing.decode(buf) },
                else => return ServerBoundPacketError.BadPacketId,
            },
            .login => switch (packet_id) {
                0x00 => .{ .login_start = try ServerLoginStart.decode(buf) },
                else => return ServerBoundPacketError.BadPacketId,
            },
            .play => switch (packet_id) {
                0x01 => .{ .play_chat_message = try ServerPlayChatMessage.decode(buf) },
                0x03 => .{ .play_player = try ServerPlayPlayer.decode(buf) },
                0x04 => .{ .play_player_position = try ServerPlayPlayerPosition.decode(buf) },
                0x05 => .{ .play_player_look = try ServerPlayPlayerLook.decode(buf) },
                0x06 => .{ .play_player_position_and_look = try ServerPlayPlayerPositionAndLook.decode(buf) },
                else => return ServerBoundPacketError.BadPacketId,
            },
        };
    }
};

pub const ClientStatusResponse = struct {
    response: []const u8,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x00)(self, buf);
    }
};

pub const ClientLoginSuccess = struct {
    uuid: []const u8,
    username: []const u8,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x02)(self, buf);
    }
};

/// The server will frequently send out a keep-alive, each containing a random ID.
/// The client must respond with the same packet.
/// If the client does not respond to them for over 30 seconds, the server kicks the client.
/// Vice versa, if the server does not send any keep-alives for 20 seconds, the client will disconnect and yields a "Timed out" exception.
pub const ClientPlayKeepAlive = struct {
    /// Keep alive ID
    id: types.VarInt,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x00)(self, buf);
    }
};

pub const ClientPlayJoinGame = struct {
    entity_id: i32,
    gamemode: u8,
    dimension: Dimension,
    difficulty: Difficulty,
    /// Used by the client to draw the player list
    max_players: u8,
    level_type: []const u8,
    reduced_debug_info: bool,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x01)(self, buf);
    }
};

/// Identifying the difference between Chat/System Message is important as it helps respect the user's chat visibility options.
/// While Position 2 accepts json formatting it will not display, old style formatting works.
pub const ClientPlayChatMessage = struct {
    json: []const u8,
    position: enum(u8) {
        chat = 0,
        system = 1,
        hotbar = 2,
    },

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x02)(self, buf);
    }
};

/// Time is based on ticks, where 20 ticks happen every second. There are 24000 ticks in a day, making Minecraft days exactly 20 minutes long.
/// The time of day is based on the timestamp modulo 24000. 0 is sunrise, 6000 is noon, 12000 is sunset, and 18000 is midnight.
/// The default SMP server increments the time by 20 every second.
pub const ClientPlayTimeUpdate = struct {
    /// World age in ticks; not changed by server commands
    world_age: i64,
    /// The world (or region) time, in ticks. If negative the sun will stop moving at the Math.abs of the time
    time_of_day: i64,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x03)(self, buf);
    }
};

/// Sent by the server to update/set the health of the player it is sent to.
/// Food acts as a food “overcharge”.
/// Food values will not decrease while the saturation is over zero.
/// Players logging in automatically get a saturation of 5.0.
/// Eating food increases the saturation as well as the food bar.
pub const ClientPlayUpdateHealth = struct {
    /// 0 or less = dead, 20 = full HP
    health: f32,
    /// 0–20
    food: types.VarInt,
    /// Seems to vary from 0.0 to 5.0 in integer increments
    food_saturation: f32,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x06)(self, buf);
    }
};

/// To change the player's dimension (overworld/nether/end), send them a respawn packet with the appropriate dimension, followed by prechunks/chunks for the new dimension, and finally a position and look packet.
/// You do not need to unload chunks, the client will do it automatically.
pub const ClientPlayRespawn = struct {
    dimension: i32,
    difficulty: Difficulty,
    gamemode: GamemodeType,
    /// Same as in Join Game
    level_type: []const u8,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x07)(self, buf);
    }
};

/// https://minecraft.wiki/w/Protocol?oldid=2772100#Player_Position_And_Look
pub const ClientPlayPlayerPositionAndLook = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    flags: u8,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x08)(self, buf);
    }
};

/// Sent whenever an entity should change animation.
pub const ClientPlayAnimation = struct {
    entity_id: types.VarInt,
    animation: enum(u8) {
        swing_arm = 0,
        take_damage = 1,
        leave_bed = 2,
        eat_food = 3,
        critical_effect = 4,
        magic_critical_effect = 5,
    },

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x0B)(self, buf);
    }
};

/// Sent by the server when someone picks up an item lying on the ground — its sole purpose appears to be the animation of the item flying towards you. It doesn't destroy the entity in the client memory, and it doesn't add it to your inventory. The server only checks for items to be picked up after each Player Position (and Player Position And Look) packet sent by the client.
pub const ClientPlayCollectItem = struct {
    collected_eid: types.VarInt,
    collector_eid: types.VarInt,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x0D)(self, buf);
    }
};

/// Spawns one or more experience orbs.
pub const ClientPlaySpawnExperienceOrb = struct {
    entity_id: types.VarInt,
    x: i32,
    y: i32,
    z: i32,
    /// The amount of experience this orb will reward once collected
    count: i16,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x11)(self, buf);
    }
};

/// Velocity is believed to be in units of 1/8000 of a block per server tick (50ms); for example, -1343 would move (-1343 / 8000) = −0.167875 blocks per tick (or −3,3575 blocks per second).
pub const ClientPlayEntityVelocity = struct {
    entity_id: types.VarInt,
    velocity_x: i32,
    vel_y: i32,
    vel_z: i32,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x12)(self, buf);
    }
};

/// This packet may be used to initialize an entity.
/// For player entities, either this packet or any move/look packet is sent every game tick.
/// So the meaning of this packet is basically that the entity did not move/look since the last such packet.
pub const ClientPlayEntity = struct {
    entity_id: types.VarInt,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x14)(self, buf);
    }
};

/// This packet is sent by the server when an entity moves less then 4 blocks; if an entity moves more than 4 blocks Entity Teleport should be sent instead.
/// This packet allows at most four blocks movement in any direction, because byte range is from -128 to 127.
pub const ClientPlayEntityRelativeMove = struct {
    entity_id: types.VarInt,
    delta_x: i8,
    delta_y: i8,
    delta_z: i8,
    on_ground: bool,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x15)(self, buf);
    }
};

pub const ClientPlayChunkData = struct {
    x: i32,
    z: i32,
    continuous: bool,
    bit_mask: u16,
    chunk: *const common.chunk.Chunk,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        var offset: usize = 5;
        offset += types.VarInt.encode(0x21, buf[offset..]) catch return EncodingError.OutOfBounds;

        offset += try encodeValue(i32, self.x, buf[offset..]);
        offset += try encodeValue(i32, self.z, buf[offset..]);
        offset += try encodeValue(bool, self.continuous, buf[offset..]);
        offset += try encodeValue(u16, self.bit_mask, buf[offset..]);

        var section_count: usize = 0;
        for (0..8) |i| {
            if ((self.bit_mask & (@as(u8, 2) << @intCast(i))) != 0) {
                section_count += 1;
            }
        }

        offset += types.VarInt.encode(@intCast(12288 * section_count + 256), buf[offset..]) catch return EncodingError.OutOfBounds;

        for (0..8) |i| {
            if ((self.bit_mask & (@as(u8, 2) << @intCast(i))) == 0) {
                continue;
            }

            for (0..4096) |j| {
                offset += try encodeValue(u16, self.chunk.sections[i].blocks[j], buf[offset..]);
            }

            for (0..2048) |j| {
                offset += try encodeValue(
                    u8,
                    (@as(u8, @intCast(self.chunk.sections[i].block_light[j * 2])) << 4) | self.chunk.sections[i].block_light[j * 2 + 1],
                    buf[offset..],
                );
            }

            for (0..2048) |j| {
                offset += try encodeValue(
                    u8,
                    (@as(u8, @intCast(self.chunk.sections[i].sky_light[j * 2])) << 4) | self.chunk.sections[i].sky_light[j * 2 + 1],
                    buf[offset..],
                );
            }
        }

        for (0..256) |i| {
            offset += try encodeValue(u8, @intFromEnum(self.chunk.biomes[i]), buf[offset..]);
        }

        const size = types.VarInt.encode(@intCast(offset - 5), buf) catch return EncodingError.OutOfBounds;
        @memmove(buf[size .. size + offset], buf[5 .. 5 + offset]);

        return size + offset - 5;
    }
};

/// Used to play a sound effect on the client.
/// Custom sounds may be added by resource packs.
pub const ClientPlaySoundEffect = struct {
    sound_name: []const u8,
    x: i32,
    y: i32,
    z: i32,
    volume: f32,
    pitch: u8,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x29)(self, buf);
    }
};

/// Sent by the server before it disconnects a client.
/// The client assumes that the server has already closed the connection by the time the packet arrives.
pub const ClientPlayDisconnect = struct {
    reason: []const u8,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x40)(self, buf);
    }
};

pub const ClientPlayTitle = union(enum) {
    set_title: []const u8,
    set_subtitle: []const u8,
    set_times: struct {
        fade_in: i32,
        stay: i32,
        fade_out: i32,
    },
    /// Makes the title disappear, but if you run times again the same title will appear.
    hide: void,
    /// Erases the text
    reset: void,

    inline fn encodeChat(
        buf: []u8,
        action: u8,
        chat: []const u8,
    ) !usize {
        var offset: usize = 0;
        offset += try encodeValue(u8, action, buf[offset..]);
        offset += try encodeValue([]const u8, chat, buf[offset..]);
        return offset;
    }

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        var offset: usize = 5;
        offset += types.VarInt.encode(0x45, buf[offset..]) catch return EncodingError.OutOfBounds;
        switch (self.*) {
            .set_title => |c| offset += try encodeChat(buf[offset..], 0, c),
            .set_subtitle => |c| offset += try encodeChat(buf[offset..], 1, c),
            .set_times => |t| {
                offset += try encodeValue(u8, 2, buf[offset..]);
                offset += try encodeValue(i32, t.fade_in, buf[offset..]);
                offset += try encodeValue(i32, t.stay, buf[offset..]);
                offset += try encodeValue(i32, t.fade_out, buf[offset..]);
            },
            .hide => offset += try encodeValue(u8, 3, buf[offset..]),
            .reset => offset += try encodeValue(u8, 4, buf[offset..]),
        }

        const size = types.VarInt.encode(@intCast(offset - 5), buf) catch return EncodingError.OutOfBounds;
        @memmove(buf[size .. size + offset], buf[5 .. 5 + offset]);

        return size + offset - 5;
    }
};
