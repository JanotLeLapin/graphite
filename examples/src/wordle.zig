const std = @import("std");

const common = @import("graphite-common");
const Chat = common.chat.Chat;
const ChatColor = common.chat.ChatColor;
const Client = common.client.Client;
const Context = common.Context;

const protocol = @import("graphite-protocol");

const NoteTaskData = packed struct(u64) {
    client_fd: i32,
    midi: u8,
    _: u24 = 0,
};

const CharStatus = enum(u2) {
    miss = 0,
    present = 1,
    spot_on = 2,

    fn getColor(self: CharStatus) ChatColor {
        return switch (self) {
            .miss => .gray,
            .present => .yellow,
            .spot_on => .green,
        };
    }
};

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
        ctx: *Context,
        client: *Client,
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

        const b = try ctx.buffer_pools.allocBuf(.@"10");

        var buf: [256]u8 = undefined;

        var offset = try protocol.ClientPlayChatMessage.encode(&.{
            .json = try std.fmt.bufPrint(
                &buf,
                "{f}",
                .{common.chat.Chat{
                    .text = "guess: ",
                    .extra = &.{
                        .{ .text = message[0..1], .color = statuses[0].getColor() },
                        .{ .text = message[1..2], .color = statuses[1].getColor() },
                        .{ .text = message[2..3], .color = statuses[2].getColor() },
                        .{ .text = message[3..4], .color = statuses[3].getColor() },
                        .{ .text = message[4..5], .color = statuses[4].getColor() },
                    },
                }},
            ),
            .position = .system,
        }, b.ptr);

        if (std.mem.eql(CharStatus, &statuses, &.{ .spot_on, .spot_on, .spot_on, .spot_on, .spot_on })) {
            try self.winners.append(self.alloc, client.fd);
            offset += try protocol.ClientPlayChatMessage.encode(&.{
                .json = try std.fmt.bufPrint(&buf, "{f}", .{Chat{ .text = "good guess!", .color = .green }}),
                .position = .system,
            }, b.ptr[offset..]);

            try ctx.scheduler.schedule(&playNoteTask, 1, @bitCast(NoteTaskData{ .client_fd = client.fd, .midi = 48 }));
            try ctx.scheduler.schedule(&playNoteTask, 6, @bitCast(NoteTaskData{ .client_fd = client.fd, .midi = 52 }));
            try ctx.scheduler.schedule(&playNoteTask, 11, @bitCast(NoteTaskData{ .client_fd = client.fd, .midi = 55 }));
            try ctx.scheduler.schedule(&playNoteTask, 11, @bitCast(NoteTaskData{ .client_fd = client.fd, .midi = 59 }));
        }

        ctx.prepareOneshot(client.fd, b, offset);
    }
};

fn playNoteTask(ctx: *Context, userdata: u64) void {
    const noteData: NoteTaskData = @bitCast(userdata);

    _ = ctx.client_manager.get(noteData.client_fd) orelse return;

    const b = ctx.buffer_pools.allocBuf(.@"6") catch return;

    const pitch = common.pitchFromMidi(noteData.midi);
    const size = protocol.ClientPlaySoundEffect.encode(
        &.{
            .sound_name = "note.harp",
            .x = 0,
            .y = 67 * 8,
            .z = 0,
            .volume = 10.0,
            .pitch = pitch,
        },
        b.ptr,
    ) catch {
        ctx.buffer_pools.releaseBuf(b.idx);
        return;
    };

    ctx.prepareOneshot(noteData.client_fd, b, size);
}
