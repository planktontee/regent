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
    const errorM = "unpack only supports packed structs or enums";
    const tInfo = @typeInfo(@TypeOf(value));
    break :T switch (tInfo) {
        .@"struct" => |sInfo| r: {
            if (sInfo.layout != .@"packed") @compileError(errorM);

            break :r sInfo.backing_integer.?;
        },
        .@"enum" => |eInfo| eInfo.tag_type,
        else => @compileError(errorM),
    };
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => @bitCast(value),
        .@"enum" => @intFromEnum(value),
        else => unreachable,
    };
}

pub inline fn unpack(T: type, value: V: {
    const errorM = "unpack only supports packed structs or enums";
    const tInfo = @typeInfo(T);
    break :V switch (tInfo) {
        .@"struct" => |sInfo| r: {
            if (sInfo.layout != .@"packed") @compileError(errorM);

            break :r sInfo.backing_integer.?;
        },
        .@"enum" => |eInfo| eInfo.tag_type,
        else => @compileError(errorM),
    };
}) T {
    return switch (@typeInfo(T)) {
        .@"struct" => @bitCast(value),
        .@"enum" => @enumFromInt(value),
        else => unreachable,
    };
}
