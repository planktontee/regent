const std = @import("std");

// This function helps type expected
pub inline fn expectEqual(comptime T: type, expected: T, actual: T) !void {
    try std.testing.expectEqual(expected, actual);
}

pub inline fn expectEqualDeep(comptime T: type, expected: T, actual: T) !void {
    try std.testing.expectEqualDeep(expected, actual);
}
