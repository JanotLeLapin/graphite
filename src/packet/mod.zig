const std = @import("std");

pub const common = @import("../common/mod.zig");

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

pub const ClientPlayKeepAlive = struct {
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
    max_players: u8,
    level_type: []const u8,
    reduced_debug_info: bool,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x01)(self, buf);
    }
};

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

pub const ClientPlayTimeUpdate = struct {
    world_age: usize,
    time_of_day: usize,

    pub fn encode(self: *const @This(), buf: []u8) !usize {
        return genEncodeBasic(@This(), 0x03)(self, buf);
    }
};

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
    hide: void,
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
