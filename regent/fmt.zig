const std = @import("std");

pub fn decimalStrSize(T: type) usize {
    switch (@typeInfo(T)) {
        .int => |intInfo| {
            return comptime std.fmt.count("{d}", .{if (intInfo.signedness == .unsigned)
                std.math.maxInt(T)
            else
                std.math.minInt(T)});
        },
        else => @compileError("Method strSize only takes ints"),
    }
}

pub fn floatTrunc(T: type, value: T, comptime floatPoints: u16) T {
    const offset: f16 = @floatFromInt(std.math.pow(u16, 10, floatPoints));
    return @trunc(value * offset) / offset;
}
