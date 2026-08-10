const std = @import("std");
const Allocator = std.mem.Allocator;

pub const blockLineFactor = 1;

pub const ComparisonMode = enum {
    lt,
    gt,
};

pub fn STree(comptime comparison: ComparisonMode, comptime K: type, comptime V: type) type {
    comptime {
        const info = @typeInfo(K);
        if (info != .int) @compileError("K must be an int, got " ++ @typeName(K));
        switch (info.int.bits) {
            8, 16, 32, 64 => {},
            else => @compileError("K must be a power of two capped at u64, got " ++ @typeName(K)),
        }

        if (@alignOf(V) > std.atomic.cache_line)
            @compileError("V alignment must not exceed cache line, got " ++ @typeName(V));
    }

    const blockBytes = std.atomic.cache_line * blockLineFactor;
    const W: usize = blockBytes / @sizeOf(K);
    if (!(W >= 4 and W % 2 == 0))
        @compileError(std.fmt.comptimePrint("cacheline * blocklineFactor/@sizeOf(K) must be >= 4 and even, got {d}", .{W}));

    return struct {
        const Self = @This();

        pub const width = W;
        pub const minKeys = W / 2 - 1;
        pub const none: u16 = std.math.maxInt(u16);
        pub const maxBlocks: usize = @as(usize, std.math.maxInt(u16));

        const KeyVec = @Vector(W, K);
        const sentinel: K = switch (comparison) {
            .lt => std.math.maxInt(K),
            .gt => std.math.minInt(K),
        };

        const keyBlockBytes = blockBytes;

        slab: []align(std.atomic.cache_line) u8,
        blocks: u16,
        // Segment ptrs
        keysPtr: [*]K,
        valsPtr: [*]V,
        childrenPtr: [*]u16,
        lensPtr: [*]u16,
        nextPtr: [*]u16,

        root: u16 = none,
        height: u16 = 0,
        head: u16 = none,
        free: u16 = 0,
        size: u32 = 0,
        // This is entirely unused, it's here for users to be able to see the absolute floor
        // without getting an error
        // mathematically it can be more
        capacity: u32,

        // guaranteedCapacity can only guarantee that the bare minimum will hold
        // but makes no promises on the upper limits
        // because left/right for inner nodes split asymetrically, worst case for
        // left-leaning or right-leaning inserts (in-order or reverse order in case of .lt)
        // can look very close to the bottom, but still different between themselves due to the fronzen
        // inner left being (if W = 16) (W / 2 - 1 = 7) and the right being 8
        // so the absolute worst case for insertion only is 7 * blocks(capacity / minkeys + 2)
        // example: 1000 capacity, W = 16, minKeys = 7, blocks = 170, worst case for insertion 1190
        // For deletion the numbers get a bit worse because of the inner node split
        // example: 1000 capacity, W = 16, minKeys = 7, blocks = 170, 7/8 all nodes for a 6.125 rate
        //          170 * 6.125 ~ 1041.25, leaves wont respect this
        // That deletion lower bound is false but a good estimate, leaves have to be there and their
        // vacancy rate is less bad
        pub fn init(allocator: Allocator, guaranteedCapacity: u32) !Self {
            const leaves = guaranteedCapacity / minKeys + 2;
            var total: usize = leaves;
            var level: usize = leaves;

            // simulates putting max nodes mathematically
            // when level / minKeys + 1 results in 1, that means we are done filling everything
            while (level > 1) {
                level = level / minKeys + 1;
                total += level;
            }

            if (total >= maxBlocks) return error.CapacityTooLarge;

            const blocks: u16 = @intCast(total);

            const keysBytes = @as(usize, blocks) * keyBlockBytes;
            const valuesOff = std.mem.alignForward(usize, keysBytes, @max(1, @alignOf(V)));
            const childrenOff = std.mem.alignForward(usize, valuesOff + @as(usize, blocks) * W * @sizeOf(V), @alignOf(u16));
            const lenOff = childrenOff + @as(usize, blocks) * (W + 1) * @sizeOf(u16);
            const nextOff = lenOff + @as(usize, blocks) * @sizeOf(u16);
            const totalBytes = nextOff + @as(usize, blocks) * @sizeOf(u16);

            const slab = try allocator.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), totalBytes);
            var self: Self = .{
                .slab = slab,
                .blocks = blocks,
                .keysPtr = @ptrCast(@alignCast(slab.ptr)),
                .valsPtr = @ptrCast(@alignCast(slab.ptr + valuesOff)),
                .childrenPtr = @ptrCast(@alignCast(slab.ptr + childrenOff)),
                .lensPtr = @ptrCast(@alignCast(slab.ptr + lenOff)),
                .nextPtr = @ptrCast(@alignCast(slab.ptr + nextOff)),
                .capacity = guaranteedCapacity,
            };

            // Free chain runs through next array, ensures swaps for free and alloc
            var b: u16 = 0;
            while (b < blocks) : (b += 1) {
                self.nexts()[b] = if (b + 1 < blocks) b + 1 else none;
            }
            return self;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.slab);
            self.* = undefined;
        }

        pub fn isSaturated(self: *const Self) bool {
            return self.size >= self.capacity;
        }

        fn keysOf(self: *const Self, b: u16) *align(std.atomic.cache_line) [W]K {
            return @ptrCast(@alignCast(self.keysPtr + @as(usize, b) * W));
        }

        fn valsOf(self: *const Self, b: u16) *[W]V {
            return @ptrCast(self.valsPtr + @as(usize, b) * W);
        }

        fn childrenOf(self: *const Self, b: u16) *[W + 1]u16 {
            return @ptrCast(self.childrenPtr + @as(usize, b) * (W + 1));
        }

        fn lens(self: *const Self) [*]u16 {
            return self.lensPtr;
        }

        fn nexts(self: *const Self) [*]u16 {
            return self.nextPtr;
        }

        fn allocBlock(self: *Self) !u16 {
            const b = self.free;
            if (b == none) {
                return error.Full;
            }

            // This is stored away to avoid forced re-calculation of ptrs
            // on store
            const nextArr = self.nexts();
            const lenArr = self.lens();
            self.free = nextArr[b];
            self.keysOf(b).* = @splat(sentinel);
            lenArr[b] = 0;
            nextArr[b] = none;
            return b;
        }

        fn freeBlock(self: *Self, b: u16) void {
            self.nexts()[b] = self.free;
            self.free = b;
        }

        fn lowerBound(keys: *align(std.atomic.cache_line) const [W]K, probe: K) u32 {
            const kv: KeyVec = keys.*;
            return switch (comptime comparison) {
                .lt => std.simd.countTrues(kv < @as(KeyVec, @splat(probe))),
                .gt => std.simd.countTrues(kv > @as(KeyVec, @splat(probe))),
            };
        }

        fn childIndex(self: *const Self, b: u16, probe: K) u32 {
            return lowerBound(self.keysOf(b), probe);
        }

        pub fn getPtr(self: *const Self, key: K) ?*V {
            if (self.root == none) return null;
            var b = self.root;
            var level = self.height;

            while (level > 0) : (level -= 1) {
                b = self.childrenOf(b)[self.childIndex(b, key)];
            }

            if (comptime @sizeOf(V) != 0) @prefetch(self.valsOf(b), .{});
            const idx = lowerBound(self.keysOf(b), key);
            if (idx >= W or self.keysOf(b)[idx] != key) return null;

            if (key == sentinel and idx >= self.lens()[b]) return null;
            return &self.valsOf(b)[idx];
        }

        pub fn get(self: *const Self, key: K) ?V {
            return (self.getPtr(key) orelse return null).*;
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.getPtr(key) != null;
        }

        fn leafInsertAt(self: *Self, b: u16, idx: u32, key: K, value: V) void {
            const lenArr = self.lens();
            const l = lenArr[b];
            std.debug.assert(l < W);
            const keys = self.keysOf(b);
            const vals = self.valsOf(b);
            @memmove(keys[idx + 1 .. l + 1], keys[idx..l]);
            @memmove(vals[idx + 1 .. l + 1], vals[idx..l]);
            keys[idx] = key;
            vals[idx] = value;
            lenArr[b] = l + 1;
        }

        fn leafRemoveAt(self: *Self, b: u16, idx: u32) void {
            const lenArr = self.lens();
            const l = lenArr[b];
            const keys = self.keysOf(b);
            const vals = self.valsOf(b);
            @memmove(keys[idx .. l - 1], keys[idx + 1 .. l]);
            @memmove(vals[idx .. l - 1], vals[idx + 1 .. l]);
            lenArr[b] = l - 1;
            keys[l - 1] = sentinel;
        }

        fn splitChild(self: *Self, parent: u16, idx: u32, childLevel: u16) !void {
            const lenArr = self.lens();
            const nextArr = self.nexts();
            std.debug.assert(self.lens()[parent] < W);

            const left = self.childrenOf(parent)[idx];

            // This is guaranteed to work based on LIFO free strategy for blocks
            // however this doesnt guarantee nexts will be contiguous, and we dont have
            // to, since nexts are wired based on index
            const right = try self.allocBlock();

            const leftKeys = self.keysOf(left);
            const rightKeys = self.keysOf(right);

            var sep: K = undefined;

            if (childLevel == 0) {
                const half = W / 2;
                @memcpy(rightKeys[0 .. W - half], leftKeys[half..W]);
                @memcpy(self.valsOf(right)[0 .. W - half], self.valsOf(left)[half..W]);
                lenArr[right] = W - half;
                @memset(leftKeys[half..W], sentinel);
                lenArr[left] = half;
                nextArr[right] = nextArr[left];
                nextArr[left] = right;
                sep = leftKeys[half - 1];
            } else {
                const mid = W / 2;
                @memcpy(rightKeys[0 .. W - mid - 1], leftKeys[mid + 1 .. W]);
                @memcpy(self.childrenOf(right)[0 .. W - mid], self.childrenOf(left)[mid + 1 .. W + 1]);
                lenArr[right] = @intCast(W - mid - 1);
                sep = leftKeys[mid];
                @memset(leftKeys[mid..W], sentinel);
                lenArr[left] = mid;
            }

            const pl = lenArr[parent];
            const pKeys = self.keysOf(parent);
            const pChildren = self.childrenOf(parent);
            @memmove(pKeys[idx + 1 .. pl + 1], pKeys[idx..pl]);
            @memmove(pChildren[idx + 2 .. pl + 2], pChildren[idx + 1 .. pl + 1]);
            pKeys[idx] = sep;
            pChildren[idx + 1] = right;
            lenArr[parent] = pl + 1;
        }

        pub fn insert(self: *Self, key: K, value: V) !?V {
            if (self.root == none) {
                const b = try self.allocBlock();
                self.keysOf(b)[0] = key;
                self.valsOf(b)[0] = value;
                self.lens()[b] = 1;
                self.root = b;
                self.head = b;
                self.size = 1;
                return null;
            }

            if (self.lens()[self.root] == W) {
                const newRoot = try self.allocBlock();
                // allocBlock set next = none, len = 0, children[0] takes old root
                self.childrenOf(newRoot)[0] = self.root;
                const oldRoot = self.root;
                self.root = newRoot;
                self.height += 1;
                // split will give newRoot it's new key
                self.splitChild(newRoot, 0, self.height - 1) catch |e| {
                    // rollback to keep tree valid
                    self.root = oldRoot;
                    self.height -= 1;
                    self.freeBlock(newRoot);
                    return e;
                };
            }

            var b = self.root;
            var level = self.height;
            while (level > 0) : (level -= 1) {
                var idx = self.childIndex(b, key);
                if (self.lens()[self.childrenOf(b)[idx]] == W) {
                    try self.splitChild(b, idx, level - 1);
                    // Key was added to parent, so it must be shifted
                    if (switch (comptime comparison) {
                        .lt => key > self.keysOf(b)[idx],
                        .gt => key < self.keysOf(b)[idx],
                    }) idx += 1;
                }
                b = self.childrenOf(b)[idx];
            }

            const keys = self.keysOf(b);
            const idx = lowerBound(keys, key);
            if (idx < self.lens()[b] and keys[idx] == key) {
                const old = self.valsOf(b)[idx];
                self.valsOf(b)[idx] = value;
                return old;
            }
            self.leafInsertAt(b, idx, key, value);
            self.size += 1;
            return null;
        }

        fn borrowFromLeft(self: *Self, parent: u16, idx: u32, childLevel: u16) void {
            const left = self.childrenOf(parent)[idx - 1];
            const child = self.childrenOf(parent)[idx];
            const lenArr = self.lens();
            const leftLen = lenArr[left];
            const leftKeys = self.keysOf(left);
            const pKeys = self.keysOf(parent);

            if (childLevel == 0) {
                self.leafInsertAt(child, 0, leftKeys[leftLen - 1], self.valsOf(left)[leftLen - 1]);
                self.leafRemoveAt(left, leftLen - 1);

                pKeys[idx - 1] = leftKeys[leftLen - 2];
            } else {
                const childLen = lenArr[child];
                const childKeys = self.keysOf(child);
                const childChildren = self.childrenOf(child);
                @memmove(childKeys[1 .. childLen + 1], childKeys[0..childLen]);
                @memmove(childChildren[1 .. childLen + 2], childChildren[0 .. childLen + 1]);
                childKeys[0] = pKeys[idx - 1];
                childChildren[0] = self.childrenOf(left)[leftLen];
                lenArr[child] = childLen + 1;
                pKeys[idx - 1] = leftKeys[leftLen - 1];
                leftKeys[leftLen - 1] = sentinel;
                lenArr[left] = leftLen - 1;
            }
        }

        fn borrowFromRight(self: *Self, parent: u16, idx: u32, childLevel: u16) void {
            const child = self.childrenOf(parent)[idx];
            const right = self.childrenOf(parent)[idx + 1];
            const lenArr = self.lens();
            const rightLen = lenArr[right];
            const rightKeys = self.keysOf(right);
            const pKeys = self.keysOf(parent);
            const childKeys = self.keysOf(child);

            if (childLevel == 0) {
                self.leafInsertAt(child, lenArr[child], rightKeys[0], self.valsOf(right)[0]);
                self.leafRemoveAt(right, 0);

                pKeys[idx] = childKeys[lenArr[child] - 1];
            } else {
                const childLen = lenArr[child];
                childKeys[childLen] = pKeys[idx];
                self.childrenOf(child)[childLen + 1] = self.childrenOf(right)[0];
                lenArr[child] = childLen + 1;
                pKeys[idx] = rightKeys[0];
                const rightChildren = self.childrenOf(right);
                @memmove(rightKeys[0 .. rightLen - 1], rightKeys[1..rightLen]);
                @memmove(rightChildren[0..rightLen], rightChildren[1 .. rightLen + 1]);
                rightKeys[rightLen - 1] = sentinel;
                lenArr[right] = rightLen - 1;
            }
        }

        fn mergeChildren(self: *Self, parent: u16, leftIdx: u32, childLevel: u16) void {
            const left = self.childrenOf(parent)[leftIdx];
            const right = self.childrenOf(parent)[leftIdx + 1];
            const lenArr = self.lens();
            const leftLen = lenArr[left];
            const rightLen = lenArr[right];
            const leftKeys = self.keysOf(left);
            const rightKeys = self.keysOf(right);
            const pkeys = self.keysOf(parent);

            if (childLevel == 0) {
                @memcpy(leftKeys[leftLen .. leftLen + rightLen], rightKeys[0..rightLen]);
                @memcpy(self.valsOf(left)[leftLen .. leftLen + rightLen], self.valsOf(right)[0..rightLen]);
                lenArr[left] = leftLen + rightLen;
                const nextArr = self.nexts();
                nextArr[left] = nextArr[right];
            } else {
                leftKeys[leftLen] = pkeys[leftIdx];
                @memcpy(leftKeys[leftLen + 1 .. leftLen + 1 + rightLen], rightKeys[0..rightLen]);
                @memcpy(self.childrenOf(left)[leftLen + 1 .. leftLen + 2 + rightLen], self.childrenOf(right)[0 .. rightLen + 1]);
                lenArr[left] = @intCast(leftLen + rightLen + 1);
            }
            self.freeBlock(right);

            const parentLen = lenArr[parent];
            const parentChildren = self.childrenOf(parent);
            @memmove(pkeys[leftIdx .. parentLen - 1], pkeys[leftIdx + 1 .. parentLen]);
            @memmove(parentChildren[leftIdx + 1 .. parentLen], parentChildren[leftIdx + 2 .. parentLen + 1]);
            pkeys[parentLen - 1] = sentinel;
            lenArr[parent] = parentLen - 1;
        }

        fn fixChild(self: *Self, parent: u16, idx: u32, childLevel: u16) u32 {
            const children = self.childrenOf(parent);
            if (idx > 0 and self.lens()[children[idx - 1]] > minKeys) {
                self.borrowFromLeft(parent, idx, childLevel);
                return idx;
            }

            if (idx < self.lens()[parent] and self.lens()[children[idx + 1]] > minKeys) {
                self.borrowFromRight(parent, idx, childLevel);
                return idx;
            }

            if (idx > 0) {
                self.mergeChildren(parent, idx - 1, childLevel);
                return idx - 1;
            }
            self.mergeChildren(parent, idx, childLevel);
            return idx;
        }

        pub fn remove(self: *Self, key: K) ?V {
            if (self.root == none) return null;
            var b = self.root;
            var level = self.height;

            while (level > 0) : (level -= 1) {
                var idx = self.childIndex(b, key);
                if (self.lens()[self.childrenOf(b)[idx]] <= minKeys) {
                    idx = self.fixChild(b, idx, level - 1);

                    if (self.lens()[b] == 0) {
                        std.debug.assert(b == self.root);
                        self.root = self.childrenOf(b)[0];
                        self.freeBlock(b);
                        self.height -= 1;
                        b = self.root;
                        continue;
                    }
                }
                b = self.childrenOf(b)[idx];
            }

            const keys = self.keysOf(b);
            const idx = lowerBound(keys, key);
            if (idx >= self.lens()[b] or keys[idx] != key) return null;
            const old = self.valsOf(b)[idx];
            self.leafRemoveAt(b, idx);
            self.size -= 1;

            if (self.lens()[b] == 0 and self.height == 0) {
                self.freeBlock(b);
                self.root = none;
                self.head = none;
            }
            return old;
        }

        pub const Entry = struct {
            key: K,
            value: *V,
        };

        pub const Iterator = struct {
            tree: *const Self,
            block: u16,
            idx: u32 = 0,

            pub fn next(it: *@This()) ?Entry {
                while (true) {
                    if (it.block == none) return null;
                    if (it.idx >= it.tree.lens()[it.block]) {
                        it.block = it.tree.nexts()[it.block];
                        it.idx = 0;
                        continue;
                    }
                    const idx = it.idx;
                    it.idx += 1;
                    return .{
                        .key = it.tree.keysOf(it.block)[idx],
                        .value = &it.tree.valsOf(it.block)[idx],
                    };
                }
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .tree = self, .block = self.head };
        }

        pub const Block = struct {
            keys: []const K,
            values: []V,
        };

        pub const BlockIterator = struct {
            tree: *const Self,
            block: u16,

            pub fn next(it: *@This()) ?Block {
                const b = it.block;
                if (b == none) return null;
                it.block = it.tree.nexts()[b];
                if (it.block != none) @prefetch(it.tree.keysOf(it.block), .{});
                const l = it.tree.lens()[b];
                return .{
                    .keys = it.tree.keysOf(b)[0..l],
                    .values = it.tree.valsOf(b)[0..l],
                };
            }
        };

        pub fn blockIterator(self: *const Self) BlockIterator {
            return .{ .tree = self, .block = self.head };
        }
    };
}

const testing = std.testing;

test "stree: sequential insert, get ordered" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u32);
        var tree: Tree = try .init(testing.allocator, 2000);
        defer tree.deinit(testing.allocator);

        const n = 1000;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            try testing.expectEqual(null, try tree.insert(i * 7, @intCast(i)));
        }
        try testing.expectEqual(n, tree.size);

        i = 0;
        while (i < n) : (i += 1) {
            try testing.expectEqual(@as(?u32, @intCast(i)), tree.get(i * 7));
            try testing.expect(!tree.contains(i * 7 + 1));
        }

        var it = tree.iterator();
        var expect: u64 = switch (mode) {
            .lt => 0,
            .gt => n - 1,
        };
        while (it.next()) |e| : (switch (mode) {
            .lt => expect += 1,
            .gt => expect -|= 1,
        }) {
            try testing.expectEqual(expect * 7, e.key);
            try testing.expectEqual(expect, e.value.*);
        }
        try testing.expectEqual(switch (mode) {
            .lt => n,
            .gt => 0,
        }, expect);
    }
}

test "stree: reverse insert stays sorted" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u64);
        var tree: Tree = try .init(testing.allocator, 1000);
        defer tree.deinit(testing.allocator);

        var i: u64 = switch (mode) {
            .lt => 500,
            .gt => 0,
        };
        while (switch (mode) {
            .lt => i > 0,
            .gt => i < 500,
        }) : (switch (mode) {
            .lt => i -= 1,
            .gt => i += 1,
        }) {
            _ = try tree.insert(i, i);
        }

        var it = tree.iterator();
        var prev: u64 = switch (mode) {
            .lt => 0,
            .gt => 500,
        };
        var seen: usize = 0;
        while (it.next()) |e| : (seen += 1) {
            try testing.expect(switch (mode) {
                .lt => e.key > prev,
                .gt => e.key < prev,
            });
            prev = e.key;
        }
        try testing.expectEqual(500, seen);
    }
}

test "stree: remove drains to empty and reuses" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u64);
        var tree: Tree = try .init(testing.allocator, 1000);
        defer tree.deinit(testing.allocator);

        const n = 800;
        var i: u64 = 0;
        while (i < n) : (i += 1) _ = try tree.insert(i, i * 2);

        i = 0;
        while (i < n) : (i += 2) {
            try testing.expectEqual(i * 2, tree.remove(i));
            try testing.expectEqual(null, tree.remove(i));
        }
        try testing.expectEqual(n / 2, tree.size);

        var it = tree.iterator();
        var expect: u64 = switch (mode) {
            .lt => 1,
            .gt => n - 1,
        };
        while (it.next()) |e| : (switch (mode) {
            .lt => expect += 2,
            .gt => expect -|= 2,
        }) {
            try testing.expectEqual(expect, e.key);
        }

        i = switch (mode) {
            .lt => 1,
            .gt => n - 1,
        };
        while (switch (mode) {
            .lt => i < n,
            .gt => i > 0,
        }) : (switch (mode) {
            .lt => i += 2,
            .gt => i -|= 2,
        }) _ = tree.remove(i);
        try testing.expectEqual(0, tree.size);
        try testing.expectEqual(null, tree.get(3));
        var emptyIt = tree.iterator();
        try testing.expectEqual(null, emptyIt.next());

        _ = try tree.insert(7, 7);
        try testing.expectEqual(7, tree.get(7));
    }
}

test "stree: error.Full at pool exhaustion, tree stays valid" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u32);
        var tree: Tree = try .init(testing.allocator, 1000);
        defer tree.deinit(testing.allocator);

        var i: u64 = 0;
        var hitFull = false;
        while (i < 100000) : (i += 1) {
            _ = tree.insert(i, @intCast(i)) catch |e| {
                try testing.expectEqual(error.Full, e);
                hitFull = true;
                break;
            };
        }
        i -= 1;
        try testing.expect(hitFull);

        var it = tree.iterator();
        var expect: u64 = switch (mode) {
            .lt => 0,
            .gt => i,
        };
        while (it.next()) |e| : (switch (mode) {
            .lt => expect += 1,
            // this will saturate but the iterator should end first
            .gt => expect -|= 1,
        }) {
            try testing.expectEqual(expect, e.key);
        }
        try testing.expectEqual(switch (mode) {
            .lt => tree.size,
            .gt => 0,
        }, expect);
    }
}

test "stree: block iterator matches entry iterator" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u32);
        var tree: Tree = try .init(testing.allocator, 3000);
        defer tree.deinit(testing.allocator);

        var prng = std.Random.DefaultPrng.init(0xB10C);
        const random = prng.random();
        var i: usize = 0;
        while (i < 2500) : (i += 1) _ = try tree.insert(random.int(u48), @intCast(i));

        i = 0;
        var prng2 = std.Random.DefaultPrng.init(0xB10C);
        const random2 = prng2.random();
        while (i < 1000) : (i += 1) _ = tree.remove(random2.int(u48));

        var entries = tree.iterator();
        var blocks = tree.blockIterator();
        var seen: usize = 0;
        while (blocks.next()) |blk| {
            for (blk.keys, blk.values) |k, v| {
                const e = entries.next().?;
                try testing.expectEqual(e.key, k);
                try testing.expectEqual(e.value.*, v);
                seen += 1;
            }
        }
        try testing.expectEqual(null, entries.next());
        try testing.expectEqual(tree.size, seen);
    }
}

test "stree: void values (set mode)" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, void);
        var set: Tree = try .init(testing.allocator, 2000);
        defer set.deinit(testing.allocator);

        var i: usize = 0;
        while (i < 1500) : (i += 1) {
            try testing.expectEqual(null, try set.insert(i * 3, {}));
        }
        try testing.expectEqual(1500, set.size);
        try testing.expect(set.contains(300));
        try testing.expect(!set.contains(301));
        try testing.expect((try set.insert(300, {})) != null);

        var it = set.iterator();
        var expect: u64 = switch (mode) {
            .lt => 0,
            .gt => 1500 - 1,
        };
        while (it.next()) |e| : (switch (mode) {
            .lt => expect += 1,
            // this will saturate but it.next will fail the next iteration
            .gt => expect -|= 1,
        }) {
            try testing.expectEqual(expect * 3, e.key);
        }
        try testing.expectEqual(switch (mode) {
            .lt => 1500,
            .gt => 0,
        }, expect);

        try testing.expect(set.remove(300) != null);
        try testing.expect(!set.contains(300));

        // Segment for values must be zero bytes for void
        var tree: STree(mode, u64, u32) = try .init(testing.allocator, 2000);
        defer tree.deinit(testing.allocator);
        try testing.expect(tree.slab.len > set.slab.len);
        try testing.expectEqual(
            tree.slab.len - @as(usize, tree.blocks) * STree(mode, u64, u32).width * @sizeOf(u32),
            set.slab.len,
        );
    }
}

test "stree: key widths derive W, natural widths work" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        inline for ([_]type{ u16, u32, u64, i32 }) |Key| {
            const Tree = STree(mode, Key, u32);
            try testing.expectEqual(
                blockLineFactor * std.atomic.cache_line,
                Tree.width * @sizeOf(Key),
            );

            var tree: Tree = try .init(testing.allocator, 3000);
            defer tree.deinit(testing.allocator);

            var prng = std.Random.DefaultPrng.init(@bitSizeOf(Key));
            const random = prng.random();
            var i: u64 = 0;
            while (i < 2000) : (i += 1) {
                _ = try tree.insert(random.int(Key), @truncate(i));
            }

            var it = tree.iterator();
            var prev: ?Key = null;
            var seen: usize = 0;
            while (it.next()) |e| : (seen += 1) {
                if (prev) |p| switch (mode) {
                    .lt => try testing.expect(e.key > p),
                    .gt => try testing.expect(e.key < p),
                };
                prev = e.key;
            }
            try testing.expectEqual(tree.size, seen);
        }
    }
}

test "stree: sentinel vs padding disambiguation" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u32);
        var tree: Tree = try .init(testing.allocator, 200);
        defer tree.deinit(testing.allocator);

        const sentinel = switch (mode) {
            .lt => std.math.maxInt(u64),
            .gt => 0,
        };

        var i: u64 = switch (mode) {
            .lt => 0,
            .gt => 100,
        };
        while (switch (mode) {
            .lt => i < 100,
            .gt => i > 0,
        }) : (switch (mode) {
            .lt => i += 1,
            .gt => i -= 1,
        }) _ = try tree.insert(i, @intCast(i));

        try testing.expectEqual(null, tree.get(sentinel));
        _ = try tree.insert(sentinel, 777);
        try testing.expectEqual(777, tree.get(sentinel));
        try testing.expectEqual(777, tree.remove(sentinel));
        try testing.expectEqual(null, tree.get(sentinel));
    }
}

test "stree: maxInt and zero keys" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u8);
        var tree: Tree = try .init(testing.allocator, 3);
        defer tree.deinit(testing.allocator);

        const sentinel = switch (mode) {
            .lt => std.math.maxInt(u64),
            .gt => 0,
        };
        const invertSentinel = switch (mode) {
            .lt => 0,
            .gt => std.math.maxInt(u64),
        };
        const adjacentToSentinel = switch (mode) {
            .lt => sentinel - 1,
            .gt => sentinel + 1,
        };

        _ = try tree.insert(sentinel, 1);
        _ = try tree.insert(invertSentinel, 2);
        _ = try tree.insert(adjacentToSentinel, 3);

        try testing.expectEqual(1, tree.get(sentinel));
        try testing.expectEqual(2, tree.get(invertSentinel));
        try testing.expectEqual(3, tree.get(adjacentToSentinel));

        try testing.expectEqual(1, tree.remove(sentinel));
        try testing.expectEqual(null, tree.get(sentinel));
        try testing.expectEqual(3, tree.get(adjacentToSentinel));
    }
}

test "stree: fuzz against hashmap reference" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = STree(mode, u64, u64);
        var tree: Tree = try .init(testing.allocator, 4096);
        defer tree.deinit(testing.allocator);

        var ref: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer ref.deinit(testing.allocator);

        var prng = std.Random.DefaultPrng.init(0x57EE);
        const random = prng.random();

        var op: usize = 0;
        while (op < 20000) : (op += 1) {
            // Forcing churn for update/removes
            const key = random.uintLessThan(u64, 4096);
            if (random.boolean()) {
                const val = random.int(u64);
                const treeOld = try tree.insert(key, val);
                const refOld = try ref.fetchPut(testing.allocator, key, val);
                try testing.expectEqual(if (refOld) |kv| kv.value else null, treeOld);
            } else {
                const treeOld = tree.remove(key);
                const refOld = ref.fetchRemove(key);
                try testing.expectEqual(if (refOld) |kv| kv.value else null, treeOld);
            }
            try testing.expectEqual(ref.count(), tree.size);
        }

        var it = tree.iterator();
        var prev: ?u64 = null;
        var seen: usize = 0;
        while (it.next()) |e| : (seen += 1) {
            if (prev) |p| switch (mode) {
                .lt => try testing.expect(e.key > p),
                .gt => try testing.expect(e.key < p),
            };
            prev = e.key;
            try testing.expectEqual(ref.get(e.key), e.value.*);
        }
        try testing.expectEqual(ref.count(), seen);
    }
}
