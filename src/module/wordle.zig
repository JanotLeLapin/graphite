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

        const b = try ctx.buffer_pool.allocBuf();
        {
            errdefer ctx.buffer_pool.releaseBuf(b.idx);

            var buf: [256]u8 = undefined;

            var offset = packet.ClientPlayChatMessage.encode(&.{
                .json = try std.fmt.bufPrint(
                    &buf,
                    "{{\"text\":\"guess: \",\"extra\":[{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}},{{\"text\":\"{c}\",\"color\":\"{s}\"}}]}}",
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

            if (std.mem.eql(CharStatus, &statuses, &.{ .SpotOn, .SpotOn, .SpotOn, .SpotOn, .SpotOn })) {
                try self.winners.append(self.alloc, client.fd);
                offset += packet.ClientPlayChatMessage.encode(&.{
                    .json = "{\"text\":\"good guess!\",\"color\":\"green\"}",
                    .position = .System,
                }, b.data[offset..]) orelse return WordleModuleError.EncodingFailure;
            }

            try b.prepareOneshot(ctx.ring, client.fd, offset);
        }
        _ = try ctx.ring.submit();
    }
};
