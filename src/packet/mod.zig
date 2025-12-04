const std = @import("std");

pub const common = @import("../common/mod.zig");

pub const types = @import("types/mod.zig");

pub const GamemodeType = enum(u8) {
    survival = 0,
    creative = 1,
    adventure = 2,
    spectator = 3,
};

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

fn genDecodeBasic(comptime T: anytype) fn ([]const u8) ?T {
    return struct {
        fn decode(buf: []const u8) ?T {
            var res: T = undefined;
            var offset: usize = 0;

            inline for (std.meta.fields(T)) |field| {
                if (offset >= buf.len) {
                    return null;
                }

                const rem = buf[offset..];
                const FieldType = field.type;

                switch (@typeInfo(FieldType)) {
                    .int, .float => {
                        const size = @sizeOf(FieldType);
                        if (rem.len < size) {
                            return null;
                        }

                        const raw = std.mem.readInt(std.meta.Int(.unsigned, size * 8), rem[0..size], .big);
                        @field(res, field.name) = @bitCast(raw);
                        offset += size;
                    },
                    .pointer => |p| {
                        if (p.size != .slice or !p.is_const or p.child != u8) {
                            std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                        }

                        const string = types.String.decode(rem) orelse return null;
                        @field(res, field.name) = string.value;
                        offset += string.len;
                    },
                    .@"struct" => {
                        const val = FieldType.decode(rem) orelse return null;
                        @field(res, field.name).value = val.value;
                        offset += val.len;
                    },
                    else => {
                        std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                    },
                }
            }

            return res;
        }
    }.decode;
}

fn genEncodeBasic(
    comptime T: anytype,
    comptime packet_id: comptime_int,
) fn (*const T, []u8) ?usize {
    return struct {
        fn encode(self: *const T, buf: []u8) ?usize {
            var offset: usize = 5;
            offset += types.VarInt.encode(packet_id, buf[offset..]) orelse return null;

            inline for (std.meta.fields(T)) |field| {
                if (offset >= buf.len) {
                    return null;
                }

                const rem = buf[offset..];
                const FieldType = field.type;

                switch (@typeInfo(FieldType)) {
                    .int, .float => {
                        const size = @sizeOf(FieldType);
                        if (rem.len < size) {
                            return null;
                        }

                        const raw: std.meta.Int(.unsigned, size * 8) = @bitCast(@field(self, field.name));
                        rem[0..size].* = @bitCast(@byteSwap(raw));
                        offset += size;
                    },
                    .@"enum" => {
                        const TagType = @typeInfo(FieldType).@"enum".tag_type;
                        const size = @sizeOf(TagType);
                        if (rem.len < size) {
                            return null;
                        }

                        std.mem.writeInt(TagType, rem[0..size], @intFromEnum(@field(self, field.name)), .big);
                        offset += size;
                    },
                    .pointer => |p| {
                        if (p.size != .slice or !p.is_const or p.child != u8) {
                            std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                        }

                        const size = types.String.encode(@field(self, field.name), rem) orelse return null;
                        offset += size;
                    },
                    .@"struct" => {
                        const size = FieldType.encode(@field(self, field.name).value, rem) orelse return null;
                        offset += size;
                    },
                    else => {
                        std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                    },
                }
            }

            const size = types.VarInt.encode(@intCast(offset - 5), buf) orelse return null;
            @memmove(buf[size .. size + offset], buf[5 .. 5 + offset]);

            return size + offset - 5;
        }
    }.encode;
}

pub const ServerHandshake = struct {
    protocol_version: types.VarInt,
    server_address: []const u8,
    server_port: u16,
    next_state: u8,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerStatusPing = struct {
    payload: u64,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerLoginStart = struct {
    username: []const u8,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayChatMessage = struct {
    message: []const u8,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayPlayer = struct {
    on_ground: u8,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayPlayerPosition = struct {
    x: f64,
    y: f64,
    z: f64,
    on_ground: u8,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ServerPlayPlayerLook = struct {
    yaw: f32,
    pitch: f32,
    on_ground: u8,

    pub fn decode(buf: []const u8) ?@This() {
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

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
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
    ) ?ServerBoundPacket {
        return switch (state) {
            .handshake => .{ .handshake = ServerHandshake.decode(buf) orelse return null },
            .status => switch (packet_id) {
                0x00 => .{ .status_request = undefined },
                0x01 => .{ .status_ping = ServerStatusPing.decode(buf) orelse return null },
                else => return null,
            },
            .login => switch (packet_id) {
                0x00 => .{ .login_start = ServerLoginStart.decode(buf) orelse return null },
                else => return null,
            },
            .play => switch (packet_id) {
                0x01 => .{ .play_chat_message = ServerPlayChatMessage.decode(buf) orelse return null },
                0x03 => .{ .play_player = ServerPlayPlayer.decode(buf) orelse return null },
                0x04 => .{ .play_player_position = ServerPlayPlayerPosition.decode(buf) orelse return null },
                0x05 => .{ .play_player_look = ServerPlayPlayerLook.decode(buf) orelse return null },
                0x06 => .{ .play_player_position_and_look = ServerPlayPlayerPositionAndLook.decode(buf) orelse return null },
                else => return null,
            },
        };
    }
};

pub const ClientStatusResponse = struct {
    response: []const u8,

    pub fn encode(self: *const @This(), buf: []u8) ?usize {
        return genEncodeBasic(@This(), 0x00)(self, buf);
    }
};

pub const ClientLoginSuccess = struct {
    uuid: []const u8,
    username: []const u8,

    pub fn encode(self: *const @This(), buf: []u8) ?usize {
        return genEncodeBasic(@This(), 0x02)(self, buf);
    }
};

pub const ClientPlayKeepAlive = struct {
    id: types.VarInt,

    pub fn encode(self: *const @This(), buf: []u8) ?usize {
        return genEncodeBasic(@This(), 0x00)(self, buf);
    }
};

pub const ClientPlayJoinGame = struct {
    eid: i32,
    gamemode: GamemodeType,
    dimension: Dimension,
    difficulty: Difficulty,
    max_players: u8,
    level_type: []const u8,
    reduced_debug_info: u8,

    pub fn encode(self: *const @This(), buf: []u8) ?usize {
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

    pub fn encode(self: *const @This(), buf: []u8) ?usize {
        return genEncodeBasic(@This(), 0x02)(self, buf);
    }
};

pub const ClientPlayPlayerPositionAndLook = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    flags: u8,

    pub fn encode(self: *const @This(), buf: []u8) ?usize {
        return genEncodeBasic(@This(), 0x08)(self, buf);
    }
};
