const std = @import("std");

pub const ChatColor = enum(u4) {
    black,
    dark_blue,
    dark_green,
    dark_aqua,
    dark_red,
    dark_purple,
    gold,
    gray,
    dark_gray,
    blue,
    green,
    aqua,
    red,
    light_purple,
    yellow,
    white,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        _ = try writer.write(@tagName(self));
    }
};

pub const Chat = struct {
    text: []const u8,
    color: ?ChatColor = null,
    extra: ?[]const Chat = null,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        _ = try writer.print("{{\"text\":\"{s}\"", .{self.text});
        if (self.color) |color| {
            _ = try writer.print(",\"color\":\"{f}\"", .{color});
        }
        if (self.extra) |extra| {
            _ = try writer.write(",\"extra\":[");
            if (extra.len > 0) {
                _ = try writer.print("{f}", .{extra[0]});
                for (extra[1..]) |comp| {
                    _ = try writer.print(",{f}", .{comp});
                }
                _ = try writer.write("]");
            }
        }
        _ = try writer.write("}");
    }
};
