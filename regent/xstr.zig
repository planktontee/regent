const std = @import("std");

pub fn toSlice(T: type, ptr: [*]const u8) T {
    const TInfoP = @typeInfo(T).pointer;

    const raw = @intFromPtr(ptr);
    const size = (raw & 0xFF00000000000000) >> 56;
    const newPtr = (raw & 0x00FFFFFFFFFFFF);

    if (TInfoP.sentinel()) |S| {
        const ptrFixed: [*:S]const u8 = @ptrFromInt(newPtr);
        return ptrFixed[0..size :S];
    } else {
        const ptrFixed: [*]const u8 = @ptrFromInt(newPtr);
        return ptrFixed[0..size];
    }
}

pub fn maskSize(ptr: [*]const u8, size: u8) [*]const u8 {
    const mask = @as(usize, @intCast(size)) << 56;
    const masked = @intFromPtr(ptr) | mask;
    return @ptrFromInt(masked);
}

pub fn cStrtoSlice(ptr: [*]const u8) [:0]const u8 {
    const raw = @intFromPtr(ptr);
    const size = (raw & 0xFF00000000000000) >> 56;
    const newPtr: [*]const u8 = @ptrFromInt(raw & 0x00FFFFFFFFFFFF);
    return newPtr[0..size :0];
}

pub const CappedStrLenError = error{
    StringTooLong,
};

pub fn strlenCapped(p: [*]const u8, cap: usize) CappedStrLenError!usize {
    if (std.simd.suggestVectorLength(u8)) |blockLen| {
        const blockSize = @sizeOf(u8) * blockLen;
        const Block = @Vector(blockLen, u8);
        const mask: Block = @splat(0);

        const pageSize = std.heap.pageSize();

        var i: usize = 0;
        const start_addr = @intFromPtr(&p[i]);
        const offset_in_page = start_addr & (pageSize - 1);
        if (offset_in_page <= pageSize - @sizeOf(Block)) {
            // Will not read past the end of a page, full block.
            const block: Block = p[i..][0..blockLen].*;
            const matches = block == mask;
            if (@reduce(.Or, matches)) {
                i += std.simd.firstTrue(matches).?;
                if (i > cap) return error.StringTooLong;
                return i;
            }

            i += @divExact(std.mem.alignForward(usize, start_addr, blockSize) - start_addr, @sizeOf(u8));
            if (i > cap) return error.StringTooLong;
        } else {
            @branchHint(.unlikely);
            // Would read over a page boundary. Per-byte at a time until aligned or found.
            // 0.39% chance this branch is taken for 4K pages at 16b block length.
            //
            // An alternate strategy is to do read a full block (the last in the page) and
            // mask the entries before the pointer.
            while ((@intFromPtr(&p[i]) & (blockSize - 1)) != 0) : (i += 1) {
                if (i > cap) return error.StringTooLong;
                if (p[i] == 0) return i;
            }
        }

        std.debug.assertAligned(&p[i], .fromByteUnits(blockSize));
        while (true) {
            const block: Block = p[i..][0..blockLen].*;
            const matches = block == mask;
            if (@reduce(.Or, matches)) {
                i += std.simd.firstTrue(matches).?;
                if (i > cap) return error.StringTooLong;
                return i;
            }
            i += blockLen;
            if (i > cap) return error.StringTooLong;
        }
    } else {
        var ptrAux = p;
        var i: usize = 0;
        while (i <= cap) : (i += 1) {
            if (ptrAux[0] == 0) return i;
            ptrAux += 1;
        }
        return error.StringTooLong;
    }
}

pub fn cStrMaskSize(ptr: [*]const u8) CappedStrLenError![*]const u8 {
    const size = try strlenCapped(ptr, 255);

    const mask = @as(usize, @intCast(size)) << 56;
    const masked = @intFromPtr(ptr) | mask;
    return @ptrFromInt(masked);
}

test "ptr test" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const a: []const u8 = "hello";
    const maskedA = maskSize(a.ptr, a.len);
    try testing.expectEqual(
        0x0500000000000000,
        @intFromPtr(maskedA) & 0xFF00000000000000,
    );
    const sliceA = toSlice([]const u8, maskedA);
    try testing.expectEqual(a, sliceA);

    const b: [:0]const u8 = " world!";
    const maskedB = try cStrMaskSize(b.ptr);
    try testing.expectEqual(
        0x0700000000000000,
        @intFromPtr(maskedB) & 0xFF00000000000000,
    );
    const sliceB = toSlice([:0]const u8, maskedB);
    try testing.expectEqual(b, sliceB);

    const c: [:0]u8 = try allocator.allocSentinel(u8, 255, 0);
    defer allocator.free(c);
    @memset(c, 'x');
    _ = &c;

    const maskedC = try cStrMaskSize(c.ptr);
    try testing.expectEqual(
        0xFF00000000000000,
        @intFromPtr(maskedC) & 0xFF00000000000000,
    );
    const sliceC = toSlice([:0]const u8, maskedC);
    try testing.expectEqual(c, sliceC);
}
