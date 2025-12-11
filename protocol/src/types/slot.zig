const std = @import("std");

const common = @import("graphite-common");

pub const Slot = struct {
    value: common.slot.SlotData,

    const DecodedType = struct {
        value: common.slot.SlotData,
        len: usize,
    };

    pub fn decode(buf: []const u8) !DecodedType {
        const id = std.mem.readInt(i16, buf[0..2], .big);
        if (id == -1) {
            return DecodedType{
                .value = .{
                    .block_id = @enumFromInt(id),
                    .item_count = 0,
                    .item_damage = 0,
                },
                .len = 2,
            };
        }

        return DecodedType{
            .value = .{
                .block_id = @enumFromInt(id),
                .item_count = buf[2],
                .item_damage = std.mem.readInt(u8, buf[3..5], .big),
            },
            .len = 6,
        };
    }

    pub fn encode(value: common.slot.SlotData, buf: []u8) !usize {
        std.mem.writeInt(i16, buf[0..2], @intFromEnum(value.block_id), .big);
        if (@intFromEnum(value.block_id) == -1) {
            return 2;
        }

        buf[2] = value.item_count;
        std.mem.writeInt(u16, buf[3..5], value.item_damage, .big);
        buf[5] = 0;
        return 6;
    }
};
