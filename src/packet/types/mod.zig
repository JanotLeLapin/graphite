const Varlen = @import("varlen.zig").Varlen;

pub const VarInt = Varlen(i32, 5);
pub const VarLong = Varlen(i64, 10);
