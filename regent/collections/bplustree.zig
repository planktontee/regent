const std = @import("std");
const Allocator = std.mem.Allocator;
const assertM = @import("../ergo.zig").assertM;

const blockLineFactor = 1;

pub const ComparisonMode = enum {
    lt,
    gt,
};

pub fn BPlusTree(comptime comparison: ComparisonMode, comptime K: type, comptime V: type) type {
    const blockByte = std.atomic.cache_line * blockLineFactor;

    comptime {
        const info = @typeInfo(K);
        if (info != .int) @compileError("K must be an int, got " ++ @typeName(K));
        switch (info.int.bits) {
            8, 16, 32, 64 => {},
            else => @compileError("K must be a power of two capped at u64, got " ++ @typeName(K)),
        }
    }

    const W: usize = blockByte / @sizeOf(K);
    if (!(W >= 4 and W % 2 == 0))
        @compileError(std.fmt.comptimePrint("cacheline * blocklineFactor/@sizeOf(K) must be >= 4 and even, got {d}", .{W}));

    return struct {
        const Self = @This();

        pub const width = W;
        // Underflow threshold for borrow/merge for internal and leaves
        // - when internal 2 minimal nodes + separator
        //   must fit and not leave full for (W / 2 - 1) + (W / 2 - 1) + 1 <= W
        // - when internal split (full and minimal)
        //   (W - W/2 - 1), which means 2 new
        // - merged node lands inside W - 2 and must be > W / 2 - 1, for W > 2
        //   this means we wont re-fix it on subsequent runs
        // With those properties we ensure insert/remove are single downwards passes
        // with a vacancy of ~3% worst case
        pub const minKeys = W / 2 - 1;

        const KeyVec = @Vector(W, K);
        const sentinel: K = switch (comparison) {
            .lt => std.math.maxInt(K),
            .gt => std.math.minInt(K),
        };
        const emptyKeys: [W]K = @splat(sentinel);

        // While descending, if at height 0, those are leafs, otherwise they are internal
        const ChildPtr = *align(std.atomic.cache_line) anyopaque;

        const Leaf = struct {
            keys: [W]K align(std.atomic.cache_line),
            vals: [W]V,
            len: u32,
            next: ?*Leaf,
        };

        const Internal = struct {
            keys: [W]K align(std.atomic.cache_line),
            // probe < keys[i] -> children[i]
            // probe == keys[i] -> children[i + 1]
            // will probe order as a mask all of keys and count, if we land on children[len - 1]
            // probe >= keys[len - 1]
            // W + 1 is for >
            // Separator is a routing value only
            children: [W + 1]ChildPtr,
            len: u32,
        };

        root: ?ChildPtr = null,
        height: u32 = 0,
        // folds merge right into left, so head is destroyed when empty
        head: ?*Leaf = null,
        size: usize = 0,

        leafPool: std.heap.MemoryPool(Leaf) = .empty,
        internalPool: std.heap.MemoryPool(Internal) = .empty,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.leafPool.deinit(allocator);
            self.internalPool.deinit(allocator);
            self.* = undefined;
        }

        // Index of the first key >= probe, results in len when all keys are smaller
        // Sentinel never counts, sentinel < probe is always false
        fn lowerBound(keys: *align(std.atomic.cache_line) const [W]K, probe: K) u32 {
            const kv: KeyVec = keys.*;
            return switch (comptime comparison) {
                .lt => std.simd.countTrues(kv < @as(KeyVec, @splat(probe))),
                .gt => std.simd.countTrues(kv > @as(KeyVec, @splat(probe))),
            };
        }

        fn childIndex(node: *const Internal, probe: K) u32 {
            return lowerBound(&node.keys, probe);
        }

        fn nodeLen(child: ChildPtr, level: u32) u32 {
            return if (level == 0)
                @as(*Leaf, @ptrCast(child)).len
            else
                @as(*Internal, @ptrCast(child)).len;
        }

        pub fn getPtr(self: *const Self, key: K) ?*V {
            var node = self.root orelse return null;
            var level = self.height;
            while (level > 0) : (level -= 1) {
                const internal: *Internal = @ptrCast(node);
                node = internal.children[childIndex(internal, key)];
            }
            const leaf: *Leaf = @ptrCast(node);
            // vals sits in a different cacheline than keys, prefetch helps to make it ready
            // for hit cases
            if (comptime @sizeOf(V) != 0) @prefetch(&leaf.vals, .{});
            const idx = lowerBound(&leaf.keys, key);
            if (idx >= leaf.len or leaf.keys[idx] != key) return null;
            return &leaf.vals[idx];
        }

        pub fn get(self: *const Self, key: K) ?V {
            return (self.getPtr(key) orelse return null).*;
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        fn newLeaf(self: *Self, allocator: Allocator) !*Leaf {
            const leaf = try self.leafPool.create(allocator);
            leaf.keys = emptyKeys;
            leaf.len = 0;
            leaf.next = null;
            return leaf;
        }

        fn leafInsertAt(leaf: *Leaf, idx: u32, key: K, value: V) void {
            std.debug.assert(leaf.len < W);
            @memmove(leaf.keys[idx + 1 .. leaf.len + 1], leaf.keys[idx..leaf.len]);
            @memmove(leaf.vals[idx + 1 .. leaf.len + 1], leaf.vals[idx..leaf.len]);
            leaf.keys[idx] = key;
            leaf.vals[idx] = value;
            leaf.len += 1;
        }

        fn leafRemoveAt(leaf: *Leaf, idx: u32) void {
            @memmove(leaf.keys[idx .. leaf.len - 1], leaf.keys[idx + 1 .. leaf.len]);
            @memmove(leaf.vals[idx .. leaf.len - 1], leaf.vals[idx + 1 .. leaf.len]);
            leaf.len -= 1;
            leaf.keys[leaf.len] = sentinel;
        }

        fn splitChild(self: *Self, allocator: Allocator, parent: *Internal, idx: u32, childLevel: u32) !void {
            std.debug.assert(parent.len < W);

            var sep: K = undefined;
            var rightPtr: ChildPtr = undefined;

            if (childLevel == 0) {
                const left: *Leaf = @ptrCast(parent.children[idx]);
                const right = try newLeaf(self, allocator);
                const half = W / 2;

                // after the movements, left[half - 1] is moved up, split happens around it
                @memcpy(right.keys[0 .. W - half], left.keys[half..W]);
                @memcpy(right.vals[0 .. W - half], left.vals[half..W]);
                right.len = W - half;
                @memset(left.keys[half..W], sentinel);
                left.len = half;

                right.next = left.next;
                left.next = right;
                sep = left.keys[half - 1];
                rightPtr = @ptrCast(right);
            } else {
                const left: *Internal = @ptrCast(parent.children[idx]);
                const right = try self.internalPool.create(allocator);
                right.keys = emptyKeys;
                const mid = W / 2;

                // left[mid] will move up, split happens around it
                @memcpy(right.keys[0 .. W - mid - 1], left.keys[mid + 1 .. W]);
                @memcpy(right.children[0 .. W - mid], left.children[mid + 1 .. W + 1]);
                right.len = W - mid - 1;
                sep = left.keys[mid];
                @memset(left.keys[mid..W], sentinel);
                left.len = mid;
                rightPtr = @ptrCast(right);
            }

            @memmove(parent.keys[idx + 1 .. parent.len + 1], parent.keys[idx..parent.len]);
            @memmove(parent.children[idx + 2 .. parent.len + 2], parent.children[idx + 1 .. parent.len + 1]);
            parent.keys[idx] = sep;
            parent.children[idx + 1] = rightPtr;
            parent.len += 1;
        }

        pub fn insert(self: *Self, allocator: Allocator, key: K, value: V) !?V {
            const root = self.root orelse {
                const leaf = try newLeaf(self, allocator);
                leaf.keys[0] = key;
                leaf.vals[0] = value;
                leaf.len = 1;
                self.root = @ptrCast(leaf);
                self.head = leaf;
                self.size = 1;
                return null;
            };

            // pre-split root, moving old root mid up
            if (nodeLen(root, self.height) == W) {
                const newRoot = try self.internalPool.create(allocator);
                newRoot.keys = emptyKeys;
                newRoot.children[0] = root;
                newRoot.len = 0;
                self.root = @ptrCast(newRoot);
                self.height += 1;
                try self.splitChild(allocator, newRoot, 0, self.height - 1);
            }

            var node = self.root.?;
            var level = self.height;
            while (level > 0) : (level -= 1) {
                const internal: *Internal = @ptrCast(node);
                var idx = childIndex(internal, key);
                if (nodeLen(internal.children[idx], level - 1) == W) {
                    try self.splitChild(allocator, internal, idx, level - 1);
                    // split put a new separator into idx, so we need to move it forward
                    if (switch (comptime comparison) {
                        .lt => key > internal.keys[idx],
                        .gt => key < internal.keys[idx],
                    }) idx += 1;
                }
                node = internal.children[idx];
            }

            const leaf: *Leaf = @ptrCast(node);
            const idx = lowerBound(&leaf.keys, key);
            if (idx < leaf.len and leaf.keys[idx] == key) {
                const old = leaf.vals[idx];
                leaf.vals[idx] = value;
                return old;
            }
            leafInsertAt(leaf, idx, key, value);
            self.size += 1;
            return null;
        }

        fn borrowFromLeft(parent: *Internal, idx: u32, childLevel: u32) void {
            if (childLevel == 0) {
                const left: *Leaf = @ptrCast(parent.children[idx - 1]);
                const child: *Leaf = @ptrCast(parent.children[idx]);
                leafInsertAt(child, 0, left.keys[left.len - 1], left.vals[left.len - 1]);
                leafRemoveAt(left, left.len - 1);
                // Move last from left to first at idx
                // since left is now smaller and child is also smaller
                // we change parent idx - 1 to last left
                // since children for parent.children[idx - 1] still holds the left
                // constraint it doesnt need to be updated
                parent.keys[idx - 1] = left.keys[left.len - 1];
            } else {
                const left: *Internal = @ptrCast(parent.children[idx - 1]);
                const child: *Internal = @ptrCast(parent.children[idx]);
                // Move forward by one
                @memmove(child.keys[1 .. child.len + 1], child.keys[0..child.len]);
                @memmove(child.children[1 .. child.len + 2], child.children[0 .. child.len + 1]);
                // borrow from parent for Internals
                child.keys[0] = parent.keys[idx - 1];
                // children[0] becomes the last from left (which holds the parent constraint)
                child.children[0] = left.children[left.len];
                child.len += 1;
                // since move last from left to parent, then remove from left
                // since children for parent.children[idx - 1] still holds the left
                // constraint it doesnt need to be updated
                parent.keys[idx - 1] = left.keys[left.len - 1];
                left.keys[left.len - 1] = sentinel;
                left.len -= 1;
            }
        }

        fn borrowFromRight(parent: *Internal, idx: u32, childLevel: u32) void {
            if (childLevel == 0) {
                const child: *Leaf = @ptrCast(parent.children[idx]);
                const right: *Leaf = @ptrCast(parent.children[idx + 1]);
                leafInsertAt(child, child.len, right.keys[0], right.vals[0]);
                leafRemoveAt(right, 0);
                // Moved from right[0] to child.len
                // parent becomes old right key
                parent.keys[idx] = child.keys[child.len - 1];
            } else {
                const child: *Internal = @ptrCast(parent.children[idx]);
                const right: *Internal = @ptrCast(parent.children[idx + 1]);
                // taken from parent, point to first rigth.child
                // holding the comparison
                child.keys[child.len] = parent.keys[idx];
                child.children[child.len + 1] = right.children[0];
                child.len += 1;

                // parent.keys[idx] will take first right and then right will be shifted by one
                parent.keys[idx] = right.keys[0];
                @memmove(right.keys[0 .. right.len - 1], right.keys[1..right.len]);
                @memmove(right.children[0..right.len], right.children[1 .. right.len + 1]);
                right.keys[right.len - 1] = sentinel;
                right.len -= 1;
            }
        }

        fn mergeChildren(self: *Self, parent: *Internal, leftIdx: u32, childLevel: u32) void {
            if (childLevel == 0) {
                const left: *Leaf = @ptrCast(parent.children[leftIdx]);
                const right: *Leaf = @ptrCast(parent.children[leftIdx + 1]);
                @memcpy(left.keys[left.len .. left.len + right.len], right.keys[0..right.len]);
                @memcpy(left.vals[left.len .. left.len + right.len], right.vals[0..right.len]);
                left.len += right.len;
                left.next = right.next;
                self.leafPool.destroy(right);
            } else {
                const left: *Internal = @ptrCast(parent.children[leftIdx]);
                const right: *Internal = @ptrCast(parent.children[leftIdx + 1]);
                // Separator comes down between merged halves
                left.keys[left.len] = parent.keys[leftIdx];
                // +1 shifted because parent key got handed down
                @memcpy(left.keys[left.len + 1 .. left.len + 1 + right.len], right.keys[0..right.len]);
                @memcpy(left.children[left.len + 1 .. left.len + 2 + right.len], right.children[0 .. right.len + 1]);
                left.len += right.len + 1;
                self.internalPool.destroy(right);
            }

            // For internal, key was handed to left, for internal -> leaf, it
            // is not needed anymore and we can safely shift left since right
            // got destroyed
            @memmove(parent.keys[leftIdx .. parent.len - 1], parent.keys[leftIdx + 1 .. parent.len]);
            @memmove(parent.children[leftIdx + 1 .. parent.len], parent.children[leftIdx + 2 .. parent.len + 1]);
            parent.keys[parent.len - 1] = sentinel;
            parent.len -= 1;
        }

        // balance children[idx] before descending by either borrowing left/right or merging
        // returns the possibly shifted index (in case merge from left happens)
        fn fixChild(self: *Self, parent: *Internal, idx: u32, childLevel: u32) u32 {
            // if not on left most, and left node has > minKeys we borrow from it
            if (idx > 0 and nodeLen(parent.children[idx - 1], childLevel) > minKeys) {
                borrowFromLeft(parent, idx, childLevel);
                return idx;
            }

            if (idx < parent.len and nodeLen(parent.children[idx + 1], childLevel) > minKeys) {
                borrowFromRight(parent, idx, childLevel);
                return idx;
            }

            // both child, left and right are minimal or empty
            // preference is to fold left (in case idx > 0)
            if (idx > 0) {
                self.mergeChildren(parent, idx - 1, childLevel);
                return idx - 1;
            }
            self.mergeChildren(parent, idx, childLevel);
            return idx;
        }

        pub fn remove(self: *Self, key: K) ?V {
            var node = self.root orelse return null;
            var level = self.height;

            while (level > 0) : (level -= 1) {
                const internal: *Internal = @ptrCast(node);
                var idx = childIndex(internal, key);
                if (nodeLen(internal.children[idx], level - 1) <= minKeys) {
                    idx = self.fixChild(internal, idx, level - 1);

                    // This only happens for merges, where the parent key moves to child
                    // at idx or idx - 1
                    // this is guaranteed to be root because every child borrows from parent
                    // if parent ends up with .len == 0, children have something
                    // the only node that can reach 0 is root because it cant borrow
                    if (internal.len == 0) {
                        std.debug.assert(@as(ChildPtr, @ptrCast(internal)) == self.root.?);
                        self.root = internal.children[0];
                        self.internalPool.destroy(internal);
                        self.height -= 1;
                        node = self.root.?;
                        continue;
                    }
                }
                node = internal.children[idx];
            }

            const leaf: *Leaf = @ptrCast(node);
            const idx = lowerBound(&leaf.keys, key);
            if (idx >= leaf.len or leaf.keys[idx] != key) return null;
            const old = leaf.vals[idx];
            leafRemoveAt(leaf, idx);
            self.size -= 1;

            if (leaf.len == 0 and self.height == 0) {
                self.leafPool.destroy(leaf);
                self.root = null;
                self.head = null;
            }

            return old;
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .leaf = self.head };
        }

        pub fn blockIterator(self: *const Self) BlockIterator {
            return .{ .leaf = self.head };
        }

        pub const Entry = struct {
            key: K,
            value: *V,
        };

        pub const Iterator = struct {
            leaf: ?*Leaf,
            idx: u32 = 0,

            pub fn next(it: *@This()) ?Entry {
                const leaf = it.leaf orelse return null;
                if (it.idx >= leaf.len) {
                    it.leaf = leaf.next;
                    it.idx = 0;
                    return it.next();
                }
                const idx = it.idx;
                it.idx += 1;
                return .{ .key = leaf.keys[idx], .value = &leaf.vals[idx] };
            }
        };

        pub const Block = struct {
            keys: []const K,
            values: []V,
        };

        pub const BlockIterator = struct {
            leaf: ?*Leaf,

            pub fn next(it: *@This()) ?Block {
                const leaf = it.leaf orelse return null;
                it.leaf = leaf.next;
                //
                if (leaf.next) |nx| @prefetch(nx, .{});
                return .{
                    .keys = leaf.keys[0..leaf.len],
                    .values = leaf.vals[0..leaf.len],
                };
            }
        };
    };
}

const testing = std.testing;

test "bplustree: sequential insert, get ordered" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = BPlusTree(mode, u64, u32);
        var tree: Tree = .empty;
        defer tree.deinit(testing.allocator);

        const n = 1000;
        var i: u64 = switch (mode) {
            .lt => 0,
            .gt => n,
        };
        while (switch (mode) {
            .lt => i < n,
            .gt => i > 0,
        }) : (switch (mode) {
            .lt => i += 1,
            .gt => i -= 1,
        }) {
            try testing.expectEqual(null, try tree.insert(testing.allocator, i * 7, @intCast(i)));
        }
        try testing.expectEqual(n, tree.size);

        i = switch (mode) {
            .lt => 0,
            .gt => n,
        };
        while (switch (mode) {
            .lt => i < n,
            .gt => i > 0,
        }) : (switch (mode) {
            .lt => i += 1,
            .gt => i -= 1,
        }) {
            try testing.expectEqual(@as(?u32, @intCast(i)), tree.get(i * 7));
            try testing.expect(!tree.contains(i * 7 + 1));
        }

        var it = tree.iterator();
        var expect: u64 = switch (mode) {
            .lt => 0,
            .gt => 1000,
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

test "bplustree: reverse insert stays sorted" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = BPlusTree(mode, u64, u64);
        var tree: Tree = .empty;
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
            _ = try tree.insert(testing.allocator, i, i);
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

test "bplustree: insert replace on duplicated keys" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = BPlusTree(mode, u64, u32);
        var tree: Tree = .empty;
        defer tree.deinit(testing.allocator);

        try testing.expectEqual(null, try tree.insert(testing.allocator, 42, 1));
        try testing.expectEqual(1, try tree.insert(testing.allocator, 42, 2));
        try testing.expectEqual(2, tree.get(42));
        try testing.expectEqual(1, tree.size);
    }
}

test "bplustree: remove: drains to empty and reuses" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = BPlusTree(mode, u64, u64);
        var tree: Tree = .empty;
        defer tree.deinit(testing.allocator);

        const n = 800;
        var i: u64 = 0;
        while (i < n) : (i += 1) _ = try tree.insert(testing.allocator, i, i * 2);

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
            // this will saturate but we should end the iterator right after
            .gt => expect -|= 2,
        }) {
            try testing.expectEqual(expect, e.key);
        }

        i = 1;
        while (i < n) : (i += 2) _ = tree.remove(i);
        try testing.expectEqual(0, tree.size);
        try testing.expectEqual(null, tree.get(3));
        var emptyIt = tree.iterator();
        try testing.expectEqual(null, emptyIt.next());

        _ = try tree.insert(testing.allocator, 7, 7);
        try testing.expectEqual(7, tree.get(7));
    }
}

test "stree: key widths derive W, natural widths work" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        inline for ([_]type{ u16, u32, u64, i32 }) |Key| {
            const Tree = BPlusTree(mode, Key, u32);
            try testing.expectEqual(
                blockLineFactor * std.atomic.cache_line,
                Tree.width * @sizeOf(Key),
            );

            var tree: Tree = .empty;
            defer tree.deinit(testing.allocator);

            var prng = std.Random.DefaultPrng.init(@bitSizeOf(Key));
            const random = prng.random();
            var i: u64 = 0;
            while (i < 2000) : (i += 1) {
                _ = try tree.insert(testing.allocator, random.int(Key), @truncate(i));
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

test "bplustree: sentinel vs padding disambiguation" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const sentinel = switch (mode) {
            .lt => std.math.maxInt(u64),
            .gt => 0,
        };

        const Tree = BPlusTree(.lt, u64, u32);
        var tree: Tree = .empty;
        defer tree.deinit(testing.allocator);

        // we reserve 0 for the boundary checks
        var i: u64 = switch (mode) {
            .lt => 0,
            .gt => 1,
        };
        while (i < 100) : (i += 1) _ = try tree.insert(testing.allocator, i, @intCast(i));

        try testing.expectEqual(null, tree.get(sentinel));
        _ = try tree.insert(testing.allocator, sentinel, 777);
        try testing.expectEqual(777, tree.get(sentinel));
        try testing.expectEqual(777, tree.remove(sentinel));
        try testing.expectEqual(null, tree.get(sentinel));
    }
}

test "bplustree: maxInt and zero keys" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = BPlusTree(mode, u64, u8);
        var tree: Tree = .empty;
        defer tree.deinit(testing.allocator);

        const max = std.math.maxInt(u64);
        _ = try tree.insert(testing.allocator, max, 1);
        _ = try tree.insert(testing.allocator, 0, 2);
        _ = try tree.insert(testing.allocator, max - 1, 3);

        try testing.expectEqual(1, tree.get(max));
        try testing.expectEqual(2, tree.get(0));
        try testing.expectEqual(3, tree.get(max - 1));

        try testing.expectEqual(1, tree.remove(max));
        try testing.expectEqual(null, tree.get(max));
        try testing.expectEqual(3, tree.get(max - 1));
    }
}

test "bplustree: block iterator matches entry iterator" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = BPlusTree(mode, u64, u32);
        var tree: Tree = .empty;
        defer tree.deinit(testing.allocator);

        var prng = std.Random.DefaultPrng.init(0xB10C);
        const random = prng.random();
        var i: usize = 0;
        while (i < 2500) : (i += 1) _ = try tree.insert(testing.allocator, random.int(u48), @intCast(i));

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

test "bplustree: fuzz against hashmap reference" {
    inline for (comptime std.meta.tags(ComparisonMode)) |mode| {
        const Tree = BPlusTree(mode, u64, u64);
        var tree: Tree = .empty;
        defer tree.deinit(testing.allocator);

        var ref: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer ref.deinit(testing.allocator);

        var prng = std.Random.DefaultPrng.init(0xB7EE);
        const random = prng.random();

        var op: usize = 0;
        while (op < 20000) : (op += 1) {
            // Forcing churn for update/removes
            const key = random.uintLessThan(u64, 4096);
            if (random.boolean()) {
                const val = random.int(u64);
                const treeOld = try tree.insert(testing.allocator, key, val);
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
