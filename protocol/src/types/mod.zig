const Varlen = @import("varlen.zig").Varlen;
pub const VarInt = Varlen(i32, 5);
pub const VarLong = Varlen(i64, 10);

pub const String = @import("string.zig").String;

pub const Location = @import("location.zig").Location;
