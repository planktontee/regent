const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const assert = std.debug.assert;
const rlinux = @import("linux.zig");
const rFs = @import("./fs.zig");

pub const Iterator = struct {
    reader: Dir.Reader,
    readerBuffer: []align(std.heap.pageSize()) u8,
    mountId: u64,

    pub fn init(dir: Dir, buff: []align(std.heap.pageSize()) u8, mountId: u64) @This() {
        return .{
            .reader = .{
                .dir = dir,
                .state = .reset,
                .index = 0,
                .end = 0,
                .buffer = buff,
            },
            .readerBuffer = buff,
            .mountId = mountId,
        };
    }

    pub const NextError = Dir.Reader.Error;

    pub fn next(
        self: *@This(),
        io: Io,
    ) NextError!?Dir.Entry {
        // reset buffer
        self.reader.buffer = self.readerBuffer;
        // We are failing at unexpected here on ex: /proc/12/task/12/net
        return self.reader.next(io);
    }

    pub fn deinit(dr: *@This(), allocator: Allocator) void {
        allocator.free(dr.readerBuffer);
        dr.readerBuffer = undefined;
        dr.* = undefined;
    }
};

pub const SelectiveWalker = struct {
    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),
    allocator: Allocator,
    visitor: std.HashMapUnmanaged(Visitor, void, std.hash_map.AutoContext(Visitor), 95),
    followSymlink: bool,

    const Visitor = struct { u64, u64 };

    pub const Error = Iterator.NextError || Allocator.Error;

    const StackItem = struct {
        iter: Iterator,
        dirname_len: usize,
        blockSize: usize,
    };

    /// After each call to this function, and on deinit(), the memory returned
    /// from this function becomes invalid. A copy must be made in order to keep
    /// a reference to the path.
    pub fn next(self: *SelectiveWalker, io: Io) Error!?Walker.Entry {
        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            var dirname_len = top.dirname_len;
            if (top.iter.next(io) catch |err| {
                // If we get an error, then we want the user to be able to continue
                // walking if they want, which means that we need to pop the directory
                // that errored from the stack. Otherwise, all future `next` calls would
                // likely just fail with the same error.
                var item = self.stack.pop().?;
                if (self.stack.items.len != 0) {
                    item.iter.reader.dir.close(io);
                }
                self.allocator.free(item.iter.readerBuffer);
                return err;
            }) |entry| {
                self.name_buffer.shrinkRetainingCapacity(dirname_len);
                if (self.name_buffer.items.len != 0) {
                    try self.name_buffer.append(self.allocator, std.fs.path.sep);
                    dirname_len += 1;
                }
                try self.name_buffer.ensureUnusedCapacity(self.allocator, entry.name.len + 1);
                self.name_buffer.appendSliceAssumeCapacity(entry.name);
                self.name_buffer.appendAssumeCapacity(0);
                const walker_entry: Walker.Entry = .{
                    .dir = top.iter.reader.dir,
                    .basename = self.name_buffer.items[dirname_len .. self.name_buffer.items.len - 1 :0],
                    .path = self.name_buffer.items[0 .. self.name_buffer.items.len - 1 :0],
                    .kind = entry.kind,
                    .inode = entry.inode,
                };
                return walker_entry;
            } else {
                var item = self.stack.pop().?;
                if (self.stack.items.len != 0) {
                    item.iter.reader.dir.close(io);
                }
                self.allocator.free(item.iter.readerBuffer);
            }
        }
        return null;
    }

    pub const EnterError = error{
        EntryAlreadyVisited,
    };

    pub fn enter(self: *SelectiveWalker, io: Io, entry: *Walker.Entry) !void {
        switch (entry.kind) {
            .directory => {
                @branchHint(.likely);

                const mountId = self.stack.items[self.stack.items.len - 1].iter.mountId;
                if (self.followSymlink and self.visitor.contains(.{ mountId, entry.inode })) return EnterError.EntryAlreadyVisited;
                try self.innerEnter(io, entry.*);
                if (self.followSymlink) try self.visitor.put(self.allocator, .{ mountId, entry.inode }, {});
            },
            .sym_link => {
                if (!self.followSymlink) return;

                const statx = fileStatLinux(
                    io,
                    entry.dir.handle,
                    entry.basename,
                    @bitCast(@as(u32, 0)),
                ) catch return;

                // update inode to target inode for symlinks
                entry.inode = statx.inode;
                if (self.visitor.contains(.{ statx.mount_id, entry.inode })) return EnterError.EntryAlreadyVisited;

                switch (statx.kind) {
                    .directory => {
                        try self.innerEnter(io, entry.*);
                        self.stack.items[self.stack.items.len - 1].iter.mountId = statx.mount_id;
                        try self.visitor.put(self.allocator, .{ statx.mount_id, entry.inode }, {});
                    },
                    else => {},
                }
            },
            else => {
                @branchHint(.cold);
                return;
            },
        }
    }

    /// Traverses into the directory, continuing walking one level down.
    fn innerEnter(self: *SelectiveWalker, io: Io, entry: Walker.Entry) !void {
        switch (entry.kind) {
            .directory, .sym_link => {
                @branchHint(.likely);
            },
            else => {
                @branchHint(.cold);
                return;
            },
        }

        assert(entry.kind == .sym_link and self.followSymlink or entry.kind != .sym_link);

        //stat symlink for files
        var new_dir = entry.dir.openDir(io, entry.basename, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.NameTooLong => unreachable,
                else => |e| return e,
            }
        };
        errdefer new_dir.close(io);

        const lastDir = self.stack.items[self.stack.items.len - 1];
        const buff: []align(std.heap.pageSize()) u8 = try self.allocator.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(std.heap.pageSize()),
            lastDir.blockSize,
        );
        errdefer self.allocator.free(buff);

        try self.stack.append(self.allocator, .{
            .iter = .init(new_dir, buff, lastDir.iter.mountId),
            .dirname_len = self.name_buffer.items.len - 1,
            .blockSize = lastDir.blockSize,
        });
    }

    pub fn deinit(self: *SelectiveWalker) void {
        self.name_buffer.deinit(self.allocator);
        for (self.stack.items) |item| {
            self.allocator.free(item.iter.readerBuffer);
        }
        self.stack.deinit(self.allocator);
        self.visitor.deinit(self.allocator);
    }

    /// Leaves the current directory, continuing walking one level up.
    /// If the current entry is a directory entry, then the "current directory"
    /// will pertain to that entry if `enter` is called before `leave`.
    pub fn leave(self: *SelectiveWalker, io: Io) void {
        var item = self.stack.pop().?;
        if (self.stack.items.len != 0) {
            @branchHint(.likely);
            item.iter.reader.dir.close(io);
        }
    }
};

pub const Walker = struct {
    inner: SelectiveWalker,
    policy: rFs.FileCursorConfig.Policy,

    pub const Entry = struct {
        /// The containing directory. This can be used to operate directly on `basename`
        /// rather than `path`, avoiding `error.NameTooLong` for deeply nested paths.
        /// The directory remains open until `next` or `deinit` is called.
        dir: Dir,
        basename: [:0]const u8,
        path: [:0]const u8,
        kind: File.Kind,
        inode: File.INode,

        /// Returns the depth of the entry relative to the initial directory.
        /// Returns 1 for a direct child of the initial directory, 2 for an entry
        /// within a direct child of the initial directory, etc.
        pub fn depth(self: Walker.Entry) usize {
            return std.mem.countScalar(u8, self.path, std.fs.path.sep) + 1;
        }
    };

    /// After each call to this function, and on deinit(), the memory returned
    /// from this function becomes invalid. A copy must be made in order to keep
    /// a reference to the path.
    pub fn next(self: *Walker, io: Io) !?Walker.Entry {
        const optEntry = try self.inner.next(io);
        if (optEntry == null) return null;
        var entry = optEntry.?;

        switch (entry.kind) {
            .sym_link,
            .directory,
            => {
                if (self.policy.interface.enter(self.policy.data, .{ .entry = entry })) {
                    try self.inner.enter(io, &entry);
                }
            },
            else => {},
        }

        if (!self.policy.interface.open(self.policy.data, .{ .entry = entry })) return error{Skipped}.Skipped;
        return entry;
    }

    pub fn deinit(self: *Walker) void {
        self.inner.deinit();
    }

    /// Leaves the current directory, continuing walking one level up.
    /// If the current entry is a directory entry, then the "current directory"
    /// is the directory pertaining to the current entry.
    pub fn leave(self: *Walker, io: Io) void {
        self.inner.leave(io);
    }
};

/// Recursively iterates over a directory, but requires the user to
/// opt-in to recursing into each directory entry.
///
/// `dir` must have been opened with `OpenOptions.iterate` set to `true`.
///
/// `Walker.deinit` releases allocated memory and directory handles.
///
/// The order of returned file system entries is undefined.
///
/// `dir` will not be closed after walking it.
///
/// See also `walk`.
pub fn walkSelectively(io: Io, dir: Dir, startPath: []const u8, allocator: Allocator, followSymlink: bool) !SelectiveWalker {
    var stack: std.ArrayList(SelectiveWalker.StackItem) = .empty;
    var visitor: @FieldType(SelectiveWalker, "visitor") = .empty;

    const statx = try fileStatLinux(
        io,
        dir.handle,
        "",
        @bitCast(@as(
            u32,
            linux.AT.EMPTY_PATH | if (comptime rlinux.kernVersionOrAbove(6, 8, 0))
                linux.AT.SYMLINK_FOLLOW
            else
                0,
        )),
    );
    const buff: []align(std.heap.pageSize()) u8 = try allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(std.heap.pageSize()),
        statx.block_size,
    );
    errdefer allocator.free(buff);

    try stack.append(allocator, .{
        .iter = Iterator.init(dir, buff, statx.mount_id),
        .dirname_len = startPath.len,
        .blockSize = statx.block_size,
    });
    errdefer stack.deinit(allocator);

    if (followSymlink) try visitor.put(allocator, .{ statx.mount_id, statx.inode }, {});

    return .{
        .stack = stack,
        .name_buffer = if (startPath.len == 0) .empty else r: {
            var nameBuff: std.ArrayList(u8) = .empty;
            try nameBuff.appendSlice(allocator, startPath);
            break :r nameBuff;
        },
        .allocator = allocator,
        .visitor = visitor,
        .followSymlink = followSymlink,
    };
}

/// Recursively iterates over a directory.
///
/// `dir` must have been opened with `OpenOptions.iterate` set to `true`.
///
/// `Walker.deinit` releases allocated memory and directory handles.
///
/// The order of returned file system entries is undefined.
///
/// `dir` will not be closed after walking it.
///
/// See also:
/// * `walkSelectively`
pub fn walk(io: Io, dir: Dir, startPath: []const u8, allocator: Allocator, followSymlink: bool, policy: rFs.FileCursorConfig.Policy) !Walker {
    return .{
        .inner = try walkSelectively(
            io,
            dir,
            startPath,
            allocator,
            followSymlink,
        ),
        .policy = policy,
    };
}

pub const statxRequest: linux.STATX = v: {
    var r: linux.STATX = .{
        .TYPE = true,
        .MODE = true,
        .ATIME = true,
        .MTIME = true,
        .CTIME = true,
        .INO = true,
        .SIZE = true,
        .NLINK = true,
        .BLOCKS = true,
    };
    if (rlinux.kernVersionOrAbove(6, 8, 0)) {
        r.MNT_ID_UNIQUE = true;
    } else {
        r.MNT_ID = true;
    }
    break :v r;
};

pub const Stat = struct {
    /// A number that the system uses to point to the file metadata. This
    /// number is not guaranteed to be unique across time, as some file
    /// systems may reuse an inode after its file has been deleted. Some
    /// systems may change the inode of a file over time.
    ///
    /// On Linux, the inode is a structure that stores the metadata, and
    /// the inode _number_ is what you see here: the index number of the
    /// inode.
    ///
    /// The FileIndex on Windows is similar. It is a number for a file that
    /// is unique to each filesystem.
    inode: File.INode,
    nlink: File.NLink,
    size: u64,
    permissions: File.Permissions,
    kind: File.Kind,
    /// Last access time in nanoseconds, relative to UTC 1970-01-01.
    ///
    /// Filesystems generally find this value problematic to keep updated since
    /// it turns read-only file system accesses into file system mutations.
    /// Some systems report stale values, and some systems explicitly refuse to
    /// report this value. The latter case is handled by `null`.
    atime: ?Io.Timestamp,
    /// Last modification time in nanoseconds, relative to UTC 1970-01-01.
    mtime: Io.Timestamp,
    /// Last status/metadata change time in nanoseconds, relative to UTC 1970-01-01.
    ctime: Io.Timestamp,
    /// Smallest chunk length in bytes appropriate for optimal I/O. This will
    /// be set to `1` for operating systems or file systems that do not
    /// recognize this concept. Not always a power of two.
    block_size: File.BlockSize,

    mount_id: u64,
};

pub const FileStatError = error{
    NoEntity,
    OperationNotPermitted,
    FileClosed,
    AddressOutOfBound,
    InvalidFlags,
    TooManySymLinks,
    PathTooLong,
    PathDoesNotExist,
} || File.StatError;

pub fn fileStatLinux(_: Io, fd: linux.fd_t, subPath: [:0]const u8, flags: linux.STATX) FileStatError!Stat {
    var statx = std.mem.zeroes(linux.Statx);
    switch (linux.errno(linux.statx(
        fd,
        subPath,
        @bitCast(flags),
        statxRequest,
        &statx,
    ))) {
        .SUCCESS => return statFromLinux(&statx),
        .ACCES => return error.AccessDenied,
        .PERM => return error.OperationNotPermitted,
        .BADF => return error.FileClosed, // File descriptor used after closed.
        .FAULT => return error.AddressOutOfBound,
        .INVAL => return error.InvalidFlags,
        .LOOP => return error.TooManySymLinks,
        .NAMETOOLONG => return error.PathTooLong,
        .NOENT => return error.NoEntity,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.PathDoesNotExist,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn statFromLinux(st: *const linux.Statx) Stat {
    const atime = st.atime;
    const mtime = st.mtime;
    const ctime = st.ctime;
    return .{
        .inode = st.ino,
        .nlink = st.nlink,
        .size = @bitCast(st.size),
        .permissions = .fromMode(st.mode),
        .kind = k: {
            const m = st.mode & linux.S.IFMT;
            switch (m) {
                linux.S.IFBLK => break :k .block_device,
                linux.S.IFCHR => break :k .character_device,
                linux.S.IFDIR => break :k .directory,
                linux.S.IFIFO => break :k .named_pipe,
                linux.S.IFLNK => break :k .sym_link,
                linux.S.IFREG => break :k .file,
                linux.S.IFSOCK => break :k .unix_domain_socket,
                else => {},
            }
            break :k .unknown;
        },
        .atime = timestampFromLinux(&atime),
        .mtime = timestampFromLinux(&mtime),
        .ctime = timestampFromLinux(&ctime),
        .block_size = @intCast(st.blksize),
        .mount_id = st.mnt_id,
    };
}

pub fn timestampFromLinux(timespec: *const linux.statx_timestamp) Io.Timestamp {
    return .{ .nanoseconds = nanosecondsFromLinux(timespec) };
}

pub fn nanosecondsFromLinux(timespec: *const linux.statx_timestamp) i96 {
    return @intCast(@as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec);
}

test "dir walk test" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    const cwd = std.Io.Dir.cwd();
    const thisDir = try cwd.openDir(io, ".", .{ .iterate = true });
    defer thisDir.close(io);

    var w = try walk(io, thisDir, ".", allocator, false, r: {
        const p = rFs.FileCursorConfig.DefaultFileCursorPolicy{};
        break :r .{
            .data = @ptrCast(@constCast(&p)),
            .interface = &.{
                .open = &rFs.FileCursorConfig.DefaultFileCursorPolicy.open,
                .enter = &rFs.FileCursorConfig.DefaultFileCursorPolicy.enter,
            },
        };
    });
    defer w.deinit();

    var visited: std.AutoHashMapUnmanaged(SelectiveWalker.Visitor, void) = .empty;
    defer visited.deinit(allocator);

    while (w.next(io) catch return) |entry| {
        const mountid = w.inner.stack.items[w.inner.stack.items.len - 1].iter.mountId;
        const key = .{ mountid, entry.inode };
        try testing.expect(!visited.contains(key));

        try visited.put(allocator, .{ mountid, entry.inode }, {});
    }
}
