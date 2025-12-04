const std = @import("std");

const common = @import("../common/mod.zig");
const packet = @import("../packet/mod.zig");

const CharStatus = enum(u2) {
    miss = 0,
    present = 1,
    spot_on = 2,

    fn getColor(self: CharStatus) common.chat.ChatColor {
        return switch (self) {
            .miss => .gray,
            .present => .yellow,
            .spot_on => .green,
        };
    }
};

pub const WordleModuleError = error{EncodingFailure};

pub const WordleModule = struct {
    word: [5]u8,

    winners: std.ArrayList(i32),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !WordleModule {
        var self = WordleModule{
            .word = undefined,
            .winners = try std.ArrayList(i32).initCapacity(alloc, 8),
            .alloc = alloc,
        };
        @memcpy(self.word[0..5], "kitty");
        return self;
    }

    pub fn deinit(self: *WordleModule) void {
        self.winners.deinit(self.alloc);
    }

    pub fn onChatMessage(
        self: *WordleModule,
        ctx: *common.Context,
        client: *common.client.Client,
        message: []const u8,
    ) !void {
        for (self.winners.items) |fd| {
            if (fd == client.fd) {
                return;
            }
        }

        if (message.len < 5) {
            return;
        }

        var statuses = std.mem.zeroes([5]CharStatus);
        for (self.word[0..5], message[0..5], 0..) |wc, mc, i| {
            if (wc == mc) {
                statuses[i] = .spot_on;
                continue;
            }

            for (self.word[0..5]) |wc2| {
                if (mc == wc2) {
                    statuses[i] = .present;
                    break;
                }
            }
        }

        const b = try ctx.buffer_pool.allocBuf();
        {
            errdefer ctx.buffer_pool.releaseBuf(b.idx);

            var buf: [256]u8 = undefined;

            var offset = packet.ClientPlayChatMessage.encode(&.{
                .json = try std.fmt.bufPrint(
                    &buf,
                    "{f}",
                    .{common.chat.Chat{
                        .text = "guess: ",
                        .extra = &[_]common.chat.Chat{
                            .{ .text = message[0..1], .color = statuses[0].getColor() },
                            .{ .text = message[1..2], .color = statuses[1].getColor() },
                            .{ .text = message[2..3], .color = statuses[2].getColor() },
                            .{ .text = message[3..4], .color = statuses[3].getColor() },
                            .{ .text = message[4..5], .color = statuses[4].getColor() },
                        },
                    }},
                ),
                .position = .system,
            }, &b.data) orelse return WordleModuleError.EncodingFailure;

            if (std.mem.eql(CharStatus, &statuses, &.{ .spot_on, .spot_on, .spot_on, .spot_on, .spot_on })) {
                try self.winners.append(self.alloc, client.fd);
                offset += packet.ClientPlayChatMessage.encode(&.{
                    .json = try std.fmt.bufPrint(&buf, "{f}", .{common.chat.Chat{ .text = "good guess!", .color = .green }}),
                    .position = .system,
                }, b.data[offset..]) orelse return WordleModuleError.EncodingFailure;
            }

            try b.prepareOneshot(ctx.ring, client.fd, offset);
        }
        _ = try ctx.ring.submit();
    }
};
