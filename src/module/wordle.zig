const std = @import("std");

const common = @import("../common/mod.zig");
const packet = @import("../packet/mod.zig");

const CharStatus = enum(u2) {
    Miss = 0,
    Present = 1,
    SpotOn = 2,

    fn getColor(self: CharStatus) []const u8 {
        return switch (self) {
            .Miss => "gray",
            .Present => "yellow",
            .SpotOn => "green",
        };
    }
};

pub const WordleModuleError = error{EncodingFailure};

pub const WordleModule = struct {
    word: [5]u8,

    pub fn init(_: std.mem.Allocator) !WordleModule {
        var self = WordleModule{ .word = undefined };
        @memcpy(self.word[0..5], "kitty");
        return self;
    }

    pub fn onChatMessage(
        self: *WordleModule,
        ctx: *common.Context,
        client: *common.client.Client,
        message: []const u8,
    ) !void {
        if (message.len < 5) {
            return;
        }

        var statuses = std.mem.zeroes([5]CharStatus);
        for (self.word[0..5], message[0..5], 0..) |wc, mc, i| {
            if (wc == mc) {
                statuses[i] = .SpotOn;
                continue;
            }

            for (self.word[0..5]) |wc2| {
                if (mc == wc2) {
                    statuses[i] = .Present;
                    break;
                }
            }
        }

        if (ctx.buffer_pool.allocBuf()) |b| {
            {
                errdefer ctx.buffer_pool.releaseBuf(b.idx);

                var buf: [256]u8 = undefined;

                const size = packet.ClientPlayChatMessage.encode(&.{
                    .json = try std.fmt.bufPrint(
                        &buf,
                        "{{\"text\":\"\",\"extra\":[{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}}]}}",
                        .{
                            message[0],
                            statuses[0].getColor(),
                            message[1],
                            statuses[1].getColor(),
                            message[2],
                            statuses[2].getColor(),
                            message[3],
                            statuses[3].getColor(),
                            message[4],
                            statuses[4].getColor(),
                        },
                    ),
                    .position = .System,
                }, &b.data) orelse return WordleModuleError.EncodingFailure;
                try b.prepareOneshot(ctx.ring, client.fd, size);
            }
            _ = try ctx.ring.submit();
        }
    }
};
