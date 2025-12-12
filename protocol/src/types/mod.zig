const Varlen = @import("varlen.zig").Varlen;
pub const VarInt = Varlen(i32, 5);
pub const VarLong = Varlen(i64, 10);

pub const string = @import("string.zig");

pub const location = @import("location.zig");
pub const slot = @import("slot.zig");
