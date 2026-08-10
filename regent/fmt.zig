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

pub inline fn pack(value: anytype) T: {
    const tInfo = @typeInfo(@TypeOf(value)).@"struct";
    if (tInfo.layout != .@"packed") @compileError("pack only supports packed structs");
    break :T tInfo.backing_integer.?;
} {
    return @bitCast(value);
}

pub inline fn unpack(T: type, value: V: {
    const tInfo = @typeInfo(T).@"struct";
    if (tInfo.layout != .@"packed") @compileError("unpack only supports packed structs");
    break :V tInfo.backing_integer.?;
}) T {
    return @bitCast(value);
}
