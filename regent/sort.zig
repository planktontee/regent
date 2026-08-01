const std = @import("std");
const Allocator = std.mem.Allocator;

const insertionThreshold = 24;

inline fn suffixLess(a: []const u8, b: []const u8, depth: usize) bool {
    const ad = a[@min(depth, a.len)..];
    const bd = b[@min(depth, b.len)..];
    return std.mem.order(u8, ad, bd) == .lt;
}

pub fn multiKeyQuickSort(allocator: Allocator, strs: [][]const u8) !void {
    if (strs.len < 2) return;

    const recs = try allocator.alloc(Record, strs.len);
    defer allocator.free(recs);

    for (recs, strs) |*r, s| r.* = .{ .chunk = loadChunk(s, 0), .str = s };
    sortCached(recs, 0);
    for (recs, strs) |r, *s| s.* = r.str;
}

const Record = struct {
    chunk: u64,
    str: []const u8,
};

inline fn loadChunk(s: []const u8, depth: usize) u64 {
    if (depth >= s.len) return 0;
    const rest = s[depth..];
    if (rest.len >= 8) return std.mem.readInt(u64, rest[0..8], .big);

    var buf: [8]u8 = @splat(0);
    @memcpy(buf[0..rest.len], rest);
    return std.mem.readInt(u64, &buf, .big);
}

fn sortCached(recsArg: []Record, depthArg: usize) void {
    var recs = recsArg;
    var depth = depthArg;

    while (recs.len > insertionThreshold) {
        const pivot = median3u64(
            recs[0].chunk,
            recs[recs.len / 2].chunk,
            recs[recs.len - 1].chunk,
        );

        // three-way partition cached chunks
        var lt: usize = 0;
        var i: usize = 0;
        var gt: usize = recs.len;
        while (i < gt) {
            const c = recs[i].chunk;
            if (c < pivot) {
                std.mem.swap(Record, &recs[lt], &recs[i]);
                lt += 1;
                i += 1;
            } else if (c > pivot) {
                gt -= 1;
                std.mem.swap(Record, &recs[i], &recs[gt]);
            } else i += 1;
        }

        // split the equal-chunk segment: string fully consumed within this
        // chunk (remaining <= 8) are done, and since chunks are equal, a
        // shorter remainder is a strict prefix of a longer one, so ordering
        // finished strings by remaining length is exact (this is also what
        // keeps zero padding distinct from real zero bytes). The rest refill
        // their chunk and descend 8 bytes
        var fin: usize = lt;
        var j: usize = lt;
        while (j < gt) : (j += 1) {
            if (recs[j].str.len -| depth <= 8) {
                std.mem.swap(Record, &recs[fin], &recs[j]);
                fin += 1;
            }
        }
        insertionSortByRem(recs[lt..fin], depth);

        const nextDepth = depth + 8;
        for (recs[fin..gt]) |*r| r.chunk = loadChunk(r.str, nextDepth);

        // recurse the two smallest segments, iterate on the largets
        const Seg = struct { off: usize, len: usize, depth: usize };
        var segs: [3]Seg = .{
            .{ .off = 0, .len = lt, .depth = depth },
            .{ .off = gt, .len = recs.len - gt, .depth = depth },
            .{ .off = fin, .len = gt - fin, .depth = nextDepth },
        };
        if (segs[0].len > segs[2].len) std.mem.swap(Seg, &segs[0], &segs[2]);
        if (segs[1].len > segs[2].len) std.mem.swap(Seg, &segs[1], &segs[2]);

        sortCached(recs[segs[0].off..][0..segs[0].len], segs[0].depth);
        sortCached(recs[segs[1].off..][0..segs[1].len], segs[1].depth);

        recs = recs[segs[2].off..][0..segs[2].len];
        depth = segs[2].depth;
    }

    insertionSortCached(recs, depth);
}

inline fn median3u64(a: u64, b: u64, c: u64) u64 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

fn insertionSortByRem(recs: []Record, depth: usize) void {
    if (recs.len < 2) return;
    for (1..recs.len) |i| {
        var j = i;
        while (j > 0 and recs[j].str.len -| depth < recs[j - 1].str.len -| depth) : (j -= 1) {
            std.mem.swap(Record, &recs[j], &recs[j - 1]);
        }
    }
}

fn insertionSortCached(recs: []Record, depth: usize) void {
    if (recs.len < 2) return;
    for (1..recs.len) |i| {
        var j = i;
        while (j > 0 and cachedLess(recs[j], recs[j - 1], depth)) : (j -= 1) {
            std.mem.swap(Record, &recs[j], &recs[j - 1]);
        }
    }
}

inline fn cachedLess(a: Record, b: Record, depth: usize) bool {
    if (a.chunk != b.chunk) return a.chunk < b.chunk;
    return suffixLess(a.str, b.str, depth);
}

const testing = std.testing;

fn expectSorted(strs: []const []const u8) !void {
    for (1..strs.len) |i| {
        try testing.expect(std.mem.order(u8, strs[i - 1], strs[i]) != .gt);
    }
}

test "multiKeyQuickSort edge cases" {
    var none: [0][]const u8 = .{};
    try multiKeyQuickSort(testing.allocator, &none);

    var one: [1][]const u8 = .{"a"};
    try multiKeyQuickSort(testing.allocator, &one);
    try testing.expectEqualStrings("a", one[0]);

    var strs: [8][]const u8 = .{ "abc", "", "ab", "abcd", "", "b", "abc", "a" };
    try multiKeyQuickSort(testing.allocator, &strs);
    for (@as([]const []const u8, &.{ "", "", "a", "ab", "abc", "abc", "abcd", "b" }), strs) |expect, got| {
        try testing.expectEqualStrings(expect, got);
    }

    var eq: [30][]const u8 = @splat("samesamesame");
    try multiKeyQuickSort(testing.allocator, &eq);
    for (eq) |s| try testing.expectEqualStrings("samesamesame", s);
}

test "multiKeyQuickSort zero padding vs real zero byte" {
    var strs: [34][]const u8 = .{
        "a\x00\x00", "a",        "a\x00",     "a\x00b",    "\x00",
        "",          "\x00\x00", "b",         "a\x00\x00", "a",
        "a\x00\x00", "a",        "a\x00",     "a\x00b",    "\x00",
        "",          "\x00\x00", "b",         "a\x00\x00", "\x00",
        "a\x00\x00", "a",        "a\x00",     "a\x00b",    "\x00",
        "",          "\x00\x00", "b",         "a\x00\x00", "a",
        "a\x00",     "a\x00b",   "\x00\x00b", "\x00b",
    };
    try multiKeyQuickSort(testing.allocator, &strs);
    for (1..strs.len) |i| {
        try testing.expect(std.mem.order(u8, strs[i - 1], strs[i]) != .gt);
    }
}

test "multiKeyQUickSort shared prefixes across chunk boundaries" {
    var strs: [30][]const u8 = .{
        "prefix00prefix00b",         "prefix00prefix00a",        "prefix00prefix00",
        "prefix00prefix00b",         "prefix00prefix00a",        "prefix00prefix00",
        "prefix00prefix00ba",        "prefix00prefix00ab",       "prefix00z",
        "prefix00prefix00b",         "prefix00prefix00a",        "prefix00prefix00",
        "prefix00prefix00prefix00x", "prefix00prefix00prefix00", "prefix00",
        "prefix00prefix00b",         "prefix00prefix00a",        "prefix00prefix00",
        "prefix00prefix00ba",        "prefix00prefix00ab",       "prefix00z",
        "prefix00prefix00b",         "prefix00prefix00a",        "prefix00prefix00",
        "prefix00prefix00prefix00x", "prefix00prefix00prefix00", "prefix00",
        "prefix01",                  "prefix0",                  "prefix00prefix0",
    };
    try multiKeyQuickSort(testing.allocator, &strs);
    for (1..strs.len) |i| {
        try testing.expect(std.mem.order(u8, strs[i - 1], strs[i]) != .gt);
    }
}

test "multiKeyQuickSort matches std sort on random data" {
    var seedBuf: [@sizeOf(u64)]u8 = undefined;
    std.Io.random(testing.io, &seedBuf);
    var prng = std.Random.DefaultPrng.init(@bitCast(seedBuf));

    const random = prng.random();

    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    for (0..16) |round| {
        const n = 1 + random.uintLessThan(usize, 500);
        const mine = try arenaAlloc.alloc([]const u8, n);
        const reference = try arenaAlloc.alloc([]const u8, n);

        for (mine) |*s| {
            const len = random.uintLessThan(usize, 40);
            const buf = try arenaAlloc.alloc(u8, len);
            for (buf) |*ch| {
                ch.* = if (round % 2 == 0)
                    'a' + random.uintLessThan(u8, 'z' - 'a' + 1)
                else
                    random.int(u8);
            }
            s.* = buf;
        }
        @memcpy(reference, mine);

        try multiKeyQuickSort(allocator, mine);
        std.mem.sortUnstable([]const u8, reference, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (reference, mine) |expect, got| {
            try testing.expectEqualStrings(expect, got);
        }
    }
}
