const std = @import("std");
const Allocator = std.mem.Allocator;
const SinglyLinkedList = std.SinglyLinkedList;

pub fn Cursor(T: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,
        curr: ?T,

        pub const VTable = struct {
            next: *const fn (*anyopaque) ?T = undefined,
        };

        pub fn next(self: *@This()) ?T {
            if (self.curr) |item| {
                self.curr = null;
                return item;
            }
            return self.vtable.next(self.ptr);
        }

        pub fn peek(self: *@This()) ?T {
            if (self.curr) |item| return item;
            self.curr = self.vtable.next(self.ptr);
            return self.curr;
        }

        pub fn consume(self: *@This()) void {
            _ = self.next();
        }

        pub fn stackItem(self: *@This(), item: T) void {
            self.curr = item;
        }
    };
}

pub fn AsCursor(comptime T: type) type {
    return struct {
        pub fn next(erased: *anyopaque) ?[]const u8 {
            const cursor: *T = @ptrCast(@alignCast(erased));
            return cursor.next();
        }
    };
}

pub const DebugCursor = struct {
    data: []const []const u8,
    i: usize = 0,

    pub fn next(cursor: *anyopaque) ?[]const u8 {
        var self: *@This() = @ptrCast(@alignCast(cursor));
        if (self.i >= self.data.len) return null;
        defer self.i += 1;
        return self.data[self.i];
    }

    pub fn asCursor(self: *@This()) Cursor([]const u8) {
        return .{
            .curr = null,
            .ptr = @ptrCast(self),
            .vtable = &.{
                .next = &@This().next,
            },
        };
    }
};

pub const DiagnosticsCursor = struct {
    lastOpt: ?[]const u8 = null,
    lastToken: ?[]const u8 = null,
    cursor: *Cursor([]const u8),

    pub fn next(cursor: *anyopaque) ?[]const u8 {
        var self: *@This() = @ptrCast(@alignCast(cursor));
        self.lastToken = self.cursor.next();
        return self.lastToken;
    }

    pub fn registerOpt(cursor: *@This(), opt: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(cursor));
        self.lastOpt = opt;
    }

    pub fn asCursor(self: *@This()) Cursor([]const u8) {
        return .{
            .curr = null,
            .ptr = @ptrCast(self),
            .vtable = &.{
                .next = &@This().next,
            },
        };
    }
};

pub fn UnitCursor(T: type) type {
    return struct {
        pub fn asCursor(item: ?T) Cursor(T) {
            return .{
                .curr = item,
                .ptr = @ptrCast(@constCast(&{})),
                .vtable = &.{
                    .next = @This().next,
                },
            };
        }

        pub fn asNoneCursor() Cursor(T) {
            return .{
                .curr = null,
                .ptr = @ptrCast(@constCast(&{})),
                .vtable = &.{
                    .next = @This().next,
                },
            };
        }

        pub fn next(cursor: *anyopaque) ?[]const u8 {
            _ = cursor;
            return null;
        }
    };
}

pub fn ArrayCursor(T: type) type {
    return struct {
        i: usize,
        list: []const T,

        pub fn init(list: []const T, start: usize) @This() {
            return .{
                .i = start,
                .list = list,
            };
        }

        pub fn asCursor(self: *@This()) Cursor(T) {
            return .{
                .curr = null,
                .ptr = self,
                .vtable = &.{
                    .next = next,
                },
            };
        }

        pub fn next(cursor: *anyopaque) ?T {
            var self: *@This() = @ptrCast(@alignCast(cursor));
            return if (self.i >= self.list.len) null else ret: {
                defer self.i += 1;
                break :ret self.list[self.i];
            };
        }
    };
}

pub fn ReverseTokenIterator(comptime T: type, comptime delimiter_type: std.mem.DelimiterType) type {
    return struct {
        buffer: []const T,
        delimiter: switch (delimiter_type) {
            .sequence, .any => []const T,
            .scalar => T,
        },
        index: usize,

        const Self = @This();

        /// Returns a slice of the current token, or null if tokenization is
        /// complete, and advances to the next token.
        pub fn next(self: *Self) ?[]const T {
            const result = self.peek() orelse return null;
            self.index -= result.len;
            return result;
        }

        /// Returns a slice of the current token, or null if tokenization is
        /// complete. Does not advance to the next token.
        pub fn peek(self: *Self) ?[]const T {
            // move to beginning of token
            while (self.index > 0 and self.isDelimiter(self.index)) : (self.index -= switch (delimiter_type) {
                .sequence => self.delimiter.len,
                .any, .scalar => 1,
            }) {}
            const end = self.index;
            if (end == 0) {
                return null;
            }

            // move to end of token
            var start = end;
            while (start > 0 and !self.isDelimiter(start)) : (start -= 1) {}

            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            // move to beginning of token
            var index: usize = self.index;
            while (index > 0 and self.isDelimiter(index)) : (index -= switch (delimiter_type) {
                .sequence => self.delimiter.len,
                .any, .scalar => 1,
            }) {}
            return self.buffer[0..index];
        }

        /// Resets the iterator to the initial token.
        pub fn reset(self: *Self) void {
            self.index = self.buffer.len;
        }

        fn isDelimiter(self: Self, index: usize) bool {
            switch (delimiter_type) {
                .sequence => return std.mem.endsWith(T, self.buffer[0..index], self.delimiter),
                .any => {
                    const item = self.buffer[index - 1];
                    for (self.delimiter) |delimiter_item| {
                        if (item == delimiter_item) {
                            return true;
                        }
                    }
                    return false;
                },
                .scalar => return self.buffer[index - 1] == self.delimiter,
            }
        }
    };
}

test "reverse tokenizer" {
    const t = std.testing;
    const s: []const u8 = "conf.type.text.banana";
    var tokenizer = ReverseTokenIterator(u8, .scalar){
        .buffer = s,
        .delimiter = '.',
        .index = s.len,
    };

    try t.expectEqualStrings("banana", tokenizer.next().?);
    try t.expectEqualStrings("text", tokenizer.next().?);
    try t.expectEqualStrings("type", tokenizer.next().?);
    try t.expectEqualStrings("conf", tokenizer.next().?);
    try t.expectEqual(null, tokenizer.next());

    const s2: []const u8 = "conf.-.type.-.text.-.banana";
    var tokenizer2 = ReverseTokenIterator(u8, .sequence){
        .buffer = s2,
        .delimiter = ".-.",
        .index = s2.len,
    };

    try t.expectEqualStrings("banana", tokenizer2.next().?);
    try t.expectEqualStrings("text", tokenizer2.next().?);
    try t.expectEqualStrings("type", tokenizer2.next().?);
    try t.expectEqualStrings("conf", tokenizer2.next().?);
    try t.expectEqual(null, tokenizer2.next());
}

pub const ComptSb = struct {
    s: []const u8,

    pub fn init(s: []const u8) *@This() {
        var b: @This() = .{
            .s = s,
        };
        return &b;
    }

    pub fn initTup(tup: anytype) *@This() {
        var b = init("");
        b.appendAll(tup);
        return b;
    }

    pub fn append(self: *@This(), piece: []const u8) void {
        self.s = self.s ++ piece;
    }

    pub fn appendAll(self: *@This(), tup: anytype) void {
        for (tup) |item| {
            self.s = self.s ++ item;
        }
    }

    pub fn prepend(self: *@This(), piece: []const u8) void {
        self.s = piece ++ self.s;
    }

    pub fn prependAll(self: *@This(), tup: anytype) void {
        for (tup) |*item| {
            self.s = item ++ self.s;
        }
    }
};
