const std = @import("std");

pub fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;

    var rem = s;
    if (std.simd.suggestVectorLength(u8)) |VLen| {
        const CharVec = @Vector(VLen, u8);

        const startVec: CharVec = @splat('0');
        const endVec: CharVec = @splat('9');

        while (rem.len >= VLen) : (rem = rem[VLen..]) {
            const vecValue: CharVec = rem[0..VLen][0..].*;

            if (@reduce(.Or, vecValue < startVec))
                return false;

            if (@reduce(.Or, vecValue > endVec))
                return false;
        }
    }

    const unrollTarget = 8;
    while (rem.len >= unrollTarget) : (rem = rem[unrollTarget..]) {
        inline for (0..unrollTarget) |i| {
            switch (rem[i]) {
                inline '0'...'9' => {},
                else => return false,
            }
        }
    }

    while (rem.len > 0) : (rem = rem[1..]) {
        switch (rem[0]) {
            inline '0'...'9' => {},
            else => return false,
        }
    }

    return true;
}

test "is str digit" {
    try std.testing.expect(!isDigits("a"));
    try std.testing.expect(isDigits("1"));
    try std.testing.expect(isDigits("9"));

    // 1 SIMD
    const simdV: [(std.simd.suggestVectorLength(u8) orelse 1)]u8 = @splat('7');
    try std.testing.expect(isDigits(&simdV));

    // 1 unrolled
    const unrolledV: [8]u8 = @splat('7');
    try std.testing.expect(isDigits(&unrolledV));

    // 1 SIMD + 1 unrolled + reminder
    const v: [(std.simd.suggestVectorLength(u8) orelse 1) + 8 + 2]u8 = simdV ++ unrolledV ++ .{ '7', '7' };
    try std.testing.expect(isDigits(&v));

    // 1 SIMD bad
    var simdVBad: [(std.simd.suggestVectorLength(u8) orelse 1)]u8 = @splat('7');
    simdVBad[0] = 'a';
    try std.testing.expect(!isDigits(&simdVBad));

    // 1 unrolled bad
    var unrolledVBad: [8]u8 = @splat('7');
    unrolledVBad[7] = 'a';
    try std.testing.expect(!isDigits(&unrolledVBad));

    // 1 SIMD + 1 unrolled + reminder bad
    var vBad: [(std.simd.suggestVectorLength(u8) orelse 1) + 8 + 2]u8 = simdV ++ unrolledV ++ .{ '7', '7' };
    vBad[vBad.len - 1] = 'a';
    try std.testing.expect(!isDigits(&vBad));
}
