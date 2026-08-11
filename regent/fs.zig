const std = @import("std");
const builtin = @import("builtin");
const ergo = @import("ergo.zig");
const mem = @import("mem.zig");
const units = @import("units.zig");
const rlinux = @import("linux.zig");
const Context = ergo.Context;
const File = std.Io.File;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assertM = ergo.assertM;
const assert = std.debug.assert;
const rDir = @import("dir.zig");

const rIO = @This();

pub const BufferType = enum {
    full,
    byte,
    mmap,
    // Buffer responsability is entirely on the caller
    unmanaged,
};

pub const Mode = enum {
    write,
    read,
};

pub const bufferAlignment = std.mem.Alignment.fromByteUnits(std.simd.suggestVectorLengthForCpu(u8, builtin.cpu) orelse 8);
pub const oDirectAlignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize());
pub const blockAlignment = std.mem.Alignment.fromByteUnits(4 * units.ByteUnit.kb);
fn resolveAlignment(comptime oDirect: bool) std.mem.Alignment {
    return if (oDirect) return oDirectAlignment else return bufferAlignment;
}

pub const BufferConfig = struct {
    blockBufferSize: usize,
    fileBufferSize: usize,
    defaultPipeSize: usize,
    maxPipeSize: usize,
    charDeviceBuff: usize,
    unixSocketBuff: usize,

    pub const defaultReaderConfig: BufferConfig = .{
        .blockBufferSize = units.ByteUnit.mb,
        .fileBufferSize = 256 * units.ByteUnit.kb,
        .defaultPipeSize = 64 * units.ByteUnit.kb,
        .maxPipeSize = units.ByteUnit.mb,
        .charDeviceBuff = 1 * units.ByteUnit.kb,
        .unixSocketBuff = 4 * units.ByteUnit.kb,
    };

    pub const defaultWriterConfig: BufferConfig = .{
        .blockBufferSize = units.ByteUnit.mb,
        .fileBufferSize = 256 * units.ByteUnit.kb,
        // We could expand the pipe here, but I'm getting some issues related to it
        .defaultPipeSize = 64 * units.ByteUnit.kb,
        .maxPipeSize = 64 * units.ByteUnit.kb,
        .charDeviceBuff = 4 * units.ByteUnit.kb,
        .unixSocketBuff = 32 * units.ByteUnit.kb,
    };

    pub fn initSame(size: usize) @This() {
        const newSize = @max(1, size);
        return .{
            .blockBufferSize = newSize,
            .fileBufferSize = newSize,
            .defaultPipeSize = newSize,
            .maxPipeSize = newSize,
            .charDeviceBuff = newSize,
            .unixSocketBuff = newSize,
        };
    }

    pub const GetError = error{UnsupportedFileType};

    pub fn get(self: @This(), kind: std.Io.File.Kind) GetError!usize {
        return switch (kind) {
            .sym_link, .door, .directory, .event_port, .unknown, .whiteout => return error.UnsupportedFileType,
            .named_pipe => self.defaultPipeSize,
            .character_device => self.charDeviceBuff,
            .block_device => self.blockBufferSize,
            .unix_domain_socket => self.unixSocketBuff,
            .file => self.fileBufferSize,
        };
    }
};

pub fn defaultBufferConfig(mode: Mode) BufferConfig {
    return switch (mode) {
        .read => .defaultReaderConfig,
        .write => .defaultWriterConfig,
    };
}

pub const OpenConfig = struct {
    oDirect: bool = false,
    expandPipe: bool = true,
    followSymlink: bool = true,

    fn convertMode(mode: Mode) std.Io.Dir.OpenFileOptions.Mode {
        return switch (mode) {
            .read => .read_only,
            .write => .write_only,
        };
    }

    pub fn validate(_: @This(), mode: Mode, openFileOptions: std.Io.Dir.OpenFileOptions) OpenError!void {
        if (openFileOptions.mode != convertMode(mode))
            return OpenError.MismatchingOpenFileOptionsAndConfig;
    }

    pub fn toOpenFileOptions(self: @This(), mode: Mode) std.Io.Dir.OpenFileOptions {
        return .{
            .mode = convertMode(mode),
            .follow_symlinks = self.followSymlink,
        };
    }
};

fn setODirect(io: Io, fd: std.os.linux.fd_t) rlinux.SetFdStatusFlagsError!void {
    try rlinux.setFdStatusFlags(io, fd, .{ .DIRECT = true });
}

fn alignODirectSize(size: usize) usize {
    const x = oDirectAlignment.toByteUnits() - 1;
    return @max(1, (size + x) & ~x);
}

fn StreamT(comptime mode: Mode) type {
    return switch (mode) {
        .read => std.Io.File.Reader,
        .write => std.Io.File.Writer,
    };
}

pub fn cwdOpen(io: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!File {
    const cwd = std.Io.Dir.cwd();
    return try cwd.openFile(io, path, options);
}

pub fn expandPipeSize(io: Io, fd: std.os.linux.fd_t, maxSize: usize) bool {
    return if (rlinux.fcntlSetPipeSZ(io, fd, maxSize)) true else |_| false;
}

pub const OpenError = error{
    FileCannotBeOpenedForRead,
    MismatchingOpenFileOptionsAndConfig,
    MMapUsedInStreamingFd,
    TBA,
} ||
    BufferConfig.GetError ||
    rlinux.SetFdStatusFlagsError ||
    std.Io.File.StatError ||
    std.Io.File.OpenError ||
    std.mem.Allocator.Error ||
    std.posix.MMapError;

pub fn OpenResponse(mode: Mode) type {
    return struct {
        stat: std.Io.File.Stat,
        stream: StreamT(mode),
        alignment: std.mem.Alignment,
        bufferType: BufferType,
    };
}

pub fn open(
    context: Context,
    path: []const u8,
    comptime mode: Mode,
    openConfig: OpenConfig,
    openFileOptions: std.Io.Dir.OpenFileOptions,
    bufferType: BufferType,
    bufferConfig: BufferConfig,
    stat: ?std.Io.File.Stat,
) OpenError!OpenResponse(mode) {
    const file = try cwdOpen(context.io, path, openFileOptions);
    errdefer file.close(context.io);

    return openStream(
        context,
        file,
        mode,
        openConfig,
        bufferType,
        bufferConfig,
        stat,
    );
}

inline fn innerOpen(
    comptime mode: Mode,
    openF: fn (File, std.Io, []u8) StreamT(mode),
    context: Context,
    stat: std.Io.File.Stat,
    file: std.Io.File,
    comptime alignment: std.mem.Alignment,
    buffSize: usize,
    bufferType: BufferType,
) OpenError!OpenResponse(mode) {
    return .{
        .stat = stat,
        .stream = openF(file, context.io, try context.allocator.alignedAlloc(
            u8,
            alignment,
            buffSize,
        )),
        .alignment = bufferAlignment,
        .bufferType = bufferType,
    };
}

// Im gonna have to find a way to move Stat out of this method
// Also I will have to change the File.Stat call to a posix.syscall instead to bypass the
// zig parser
// stat has to be Io'd
pub fn openStream(
    context: Context,
    file: File,
    comptime mode: Mode,
    openConfig: OpenConfig,
    argBufferType: BufferType,
    bufferConfig: BufferConfig,
    optStat: ?std.Io.File.Stat,
) OpenError!OpenResponse(mode) {
    var bufferType = argBufferType;

    const T = StreamT(mode);
    const openStreamingF: fn (File, std.Io, []u8) T = switch (mode) {
        .read => File.readerStreaming,
        .write => File.writerStreaming,
    };
    const openPositionalF: fn (File, std.Io, []u8) T = switch (mode) {
        .read => File.reader,
        .write => File.writer,
    };

    const oDirect = openConfig.oDirect;
    const stat = if (optStat) |stt| stt else try file.stat(context.io);

    typeLoop: switch (bufferType) {
        .byte => switch (stat.kind) {
            .character_device, .unix_domain_socket => return try innerOpen(
                mode,
                openStreamingF,
                context,
                stat,
                file,
                bufferAlignment,
                try bufferConfig.get(stat.kind),
                bufferType,
            ),
            .named_pipe => {
                var pipeSize = bufferConfig.defaultPipeSize;
                if (openConfig.expandPipe and bufferConfig.maxPipeSize > pipeSize) {
                    // Attempt to set pipesize to 1mb, this is best effort
                    if (expandPipeSize(context.io, file.handle, bufferConfig.maxPipeSize))
                        pipeSize = bufferConfig.maxPipeSize;
                }

                // ODirect and types are ignored since pipes can only be read buffered
                return try innerOpen(
                    mode,
                    openStreamingF,
                    context,
                    stat,
                    file,
                    bufferAlignment,
                    pipeSize,
                    bufferType,
                );
            },
            .block_device => {
                if (oDirect) try setODirect(context.io, file.handle);
                return try innerOpen(
                    mode,
                    openPositionalF,
                    context,
                    stat,
                    file,
                    blockAlignment,
                    if (oDirect)
                        alignODirectSize(bufferConfig.blockBufferSize)
                    else
                        bufferConfig.blockBufferSize,
                    bufferType,
                );
            },
            .file => inline for (0..2) |cBoolResolver| {
                if ((cBoolResolver == 1) == oDirect) {
                    const cODirect = cBoolResolver == 1;
                    if (cODirect) try setODirect(context.io, file.handle);

                    const bufferSize = if (cODirect)
                        alignODirectSize(bufferConfig.fileBufferSize)
                    else
                        bufferConfig.fileBufferSize;
                    return try innerOpen(
                        mode,
                        openPositionalF,
                        context,
                        stat,
                        file,
                        resolveAlignment(cODirect),
                        bufferSize,
                        bufferType,
                    );
                }
            } else unreachable,
            else => unreachable,
        },
        .full => switch (stat.kind) {
            .character_device, .unix_domain_socket, .named_pipe => {
                bufferType = .byte;
                continue :typeLoop bufferType;
            },
            .block_device => return error.TBA,
            .file => inline for (0..2) |cBoolResolver| {
                if ((cBoolResolver == 1) == oDirect) {
                    const cODirect = cBoolResolver == 1;
                    if (cODirect) try setODirect(context.io, file.handle);

                    const statSizeBuff: usize = @max(1, stat.size);
                    const bufferSize = if (cODirect)
                        alignODirectSize(statSizeBuff)
                    else
                        statSizeBuff;
                    return try innerOpen(
                        mode,
                        openPositionalF,
                        context,
                        stat,
                        file,
                        resolveAlignment(cODirect),
                        bufferSize,
                        bufferType,
                    );
                }
            } else unreachable,
            else => unreachable,
        },
        .mmap => switch (stat.kind) {
            .character_device, .unix_domain_socket, .named_pipe => return error.MMapUsedInStreamingFd,
            .block_device => return error.TBA,
            .file => switch (mode) {
                .read => {
                    const ptr = try std.posix.mmap(
                        null,
                        // MMAP fails with 0, so min has to 1
                        @max(@as(usize, @intCast(stat.size)), 1),
                        .{ .READ = true },
                        .{ .TYPE = .PRIVATE },
                        file.handle,
                        0,
                    );

                    var stream = openPositionalF(file, context.io, ptr);
                    stream.interface.end = stat.size;
                    stream.pos = stat.size;
                    stream.size = stat.size;
                    return .{
                        .stat = stat,
                        .stream = stream,
                        .alignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize()),
                        .bufferType = bufferType,
                    };
                },
                .write => return error.TBA,
            },
            else => unreachable,
        },
        .unmanaged => return .{
            .stat = stat,
            .stream = switch (stat.kind) {
                .character_device, .unix_domain_socket, .named_pipe => openStreamingF(file, context.io, &.{}),
                .block_device, .file => openPositionalF(file, context.io, &.{}),
                else => unreachable,
            },
            .alignment = bufferAlignment,
            .bufferType = bufferType,
        },
    }
}

pub fn FileStream(mode: Mode) type {
    return struct {
        stream: StreamT(mode),
        stat: std.Io.File.Stat,
        bufferType: BufferType,
        // if bufferType is .unmanaged, this is merely a suggestion
        // user is responsible for filling the correct value before calling deinit
        alignment: std.mem.Alignment,

        pub const DefaultBufferType: BufferType = .byte;

        pub fn open(
            context: Context,
            path: []const u8,
        ) OpenError!@This() {
            const openConfig: OpenConfig = .{};
            const r = try rIO.open(
                context,
                path,
                mode,
                openConfig,
                openConfig.toOpenFileOptions(mode),
                DefaultBufferType,
                defaultBufferConfig(mode),
                null,
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = r.bufferType,
                .alignment = r.alignment,
            };
        }

        pub fn openStream(
            context: Context,
            file: File,
        ) OpenError!@This() {
            const r = try rIO.openStream(
                context,
                file,
                mode,
                .{},
                DefaultBufferType,
                defaultBufferConfig(mode),
                null,
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = r.bufferType,
                .alignment = r.alignment,
            };
        }

        pub fn openWithConfig(
            context: Context,
            path: []const u8,
            openConfig: OpenConfig,
            openFileOptions: std.Io.Dir.OpenFileOptions,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
            stat: ?std.Io.File.Stat,
        ) OpenError!@This() {
            try openConfig.validate(mode, openFileOptions);
            const r = try rIO.open(
                context,
                path,
                mode,
                openConfig,
                openFileOptions,
                bufferType,
                bufferConfig,
                stat,
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = r.bufferType,
                .alignment = r.alignment,
            };
        }

        pub fn openStreamWithConfig(
            context: Context,
            file: File,
            openConfig: OpenConfig,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
            stat: ?std.Io.File.Stat,
        ) OpenError!@This() {
            const r = try rIO.openStream(
                context,
                file,
                mode,
                openConfig,
                bufferType,
                bufferConfig,
                stat,
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = r.bufferType,
                .alignment = r.alignment,
            };
        }

        pub fn fadvise(
            self: @This(),
            context: Context,
            offset: usize,
            len: usize,
            flags: []const rlinux.FADVISE,
        ) void {
            for (flags) |flag| {
                rlinux.fadvise(
                    context.io,
                    self.stream.file.handle,
                    offset,
                    len,
                    flag,
                ) catch continue;
            }
        }

        pub fn setBuffer(self: *@This(), comptime alignment: std.mem.Alignment, buffer: []u8) void {
            self.alignment = alignment;
            self.stream.interface.buffer = buffer;
            self.stream.interface.end = 0;
            self.stream.interface.seek = 0;
        }

        pub fn setMmapBuffer(self: *@This()) OpenError!void {
            if (self.stat.kind != .file) return error.MMapUsedInStreamingFd;

            const ptr = try std.posix.mmap(
                null,
                // MMAP fails with 0, so min has to 1
                @max(@as(usize, @intCast(self.stat.size)), 1),
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                self.stream.file.handle,
                0,
            );

            self.stream.interface.buffer = ptr;
            self.stream.interface.end = self.stat.size;
            self.stream.pos = self.stat.size;
            self.stream.size = self.stat.size;
            self.bufferType = .mmap;
            self.alignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize());
        }

        inline fn resizeTarget(capacity: usize) usize {
            return @max(capacity + capacity / 2, capacity + 1);
        }

        inline fn resizeReaderBuff(r: *std.Io.Reader, resizeable: anytype, allocator: Allocator, offset: usize) !void {
            // Internally ensureTotalCapacity wont expand or use past items.len for resize/remap, so we need
            // this in order to retain because we arent fiddling with this buffer from inside the arraylist
            resizeable.expandToCapacity();
            try resizeable.ensureTotalCapacity(allocator, resizeTarget(resizeable.capacity));
            r.buffer = resizeable.allocatedSlice()[offset..];
        }

        inline fn statExhausted(self: *const @This()) bool {
            return self.stat.size != 0 and self.stream.pos >= self.stat.size;
        }

        // While retain guarantees that the line will be retained in the resizeable input,
        // lines returned by this method are not guaranteed to have their lifecycle tied to
        // the actualy resizeable buffer
        // that happens because on resize, all items move to a new contiguous memory area
        // updates for consistency will require to know the first array len, then you can update
        // all ptrs accordingly for line references
        // another option is to store the old ptr so you can delta and then offset the new one
        pub fn readLineRetained(
            self: *@This(),
            allocator: std.mem.Allocator,
            // This is supposed to be a std.ArrayListAlignedUnmanaged, using anytype will
            // allow for ducktyping of the alignment
            resizeable: anytype,
        ) !?[]const u8 {
            const r: *std.Io.Reader = &self.stream.interface;
            var isDone = false;
            var target = @min(r.end + 1, r.buffer.len);
            while (r.buffer.len > 0) {
                // this happens after size discovery, helps skip probe syscall for end
                if (self.stream.size) |size| {
                    if (size != 0 and resizeable.capacity >= size) isDone = true;
                }
                // this happens preemptively for stat'd files, helps skip probe syscall for end
                if (self.statExhausted()) isDone = true;

                if (!isDone) {
                    @branchHint(.likely);
                    r.fill(target) catch |e| switch (e) {
                        error.EndOfStream => isDone = true,
                        else => return e,
                    };

                    // if we are done draining after fill
                    if (self.statExhausted()) isDone = true;
                }

                var buffered = r.buffered();
                if (std.mem.findScalar(u8, buffered, '\n')) |idx| {
                    if (!isDone and r.buffer.len == idx + 1) {
                        const bufferStartOffset = resizeable.capacity - r.buffer.len;
                        try resizeReaderBuff(r, resizeable, allocator, bufferStartOffset);
                    }

                    const result = r.buffered();
                    r.buffer = r.buffer[idx + 1 ..];
                    r.seek = 0;
                    r.end = buffered.len - idx - 1;

                    return result[0 .. idx + 1];
                } else {
                    if (isDone) {
                        if (buffered.len == 0) return null;

                        r.buffer = buffered[buffered.len..];
                        r.seek = 0;
                        r.end = 0;
                        return buffered;
                    }

                    // tail end matches capacity, the only parts that are missing are the 'beginning'
                    // which have been sliced off as part of the delimiter search hits, now we need to
                    // read more things, which means we need to preserve what was buffered and request more
                    // bufferStartOffset represents where r.buffer started considered the original buffer
                    const bufferStartOffset = resizeable.capacity - r.buffer.len;
                    try resizeReaderBuff(r, resizeable, allocator, bufferStartOffset);
                    target = r.end + 1;
                }
            }
            return null;
        }

        pub fn readFileRetained(
            self: *@This(),
            allocator: std.mem.Allocator,
            // This is supposed to be a std.ArrayListAlignedUnmanaged, using anytype will
            // allow for ducktyping of the alignment
            resizeable: anytype,
        ) ![]const u8 {
            const r: *std.Io.Reader = &self.stream.interface;
            while (true) {
                // this happens after size discovery
                if (self.stream.size) |size|
                    if (size != 0 and r.bufferedLen() == size) return r.buffered();
                // this happens preemptively for stat'd files, helps skip probe syscall for end
                if (self.statExhausted()) return r.buffered();

                // This alongs with the pre-check and post-check for size, ensures we can skip zero-read probe for
                // when stat is known
                const target = if (self.stat.size != 0)
                    @min(r.buffer.len, r.bufferedLen() + @as(usize, @intCast(self.stat.size -| self.stream.pos)))
                else
                    r.buffer.len;

                r.fill(target) catch |e| switch (e) {
                    error.EndOfStream => return r.buffered(),
                    else => return e,
                };

                // Avoid expansion when file is done
                if (self.stream.size) |size|
                    if (size != 0 and r.bufferedLen() == size) return r.buffered();
                if (self.statExhausted()) return r.buffered();

                try resizeReaderBuff(r, resizeable, allocator, 0);
            }
            unreachable;
        }

        pub fn readOnceAll(self: *@This()) ![]const u8 {
            return _fs.readOnceAll(&self.stream.interface);
        }

        pub fn close(self: *@This(), context: Context) void {
            self.stream.file.close(context.io);
        }

        pub fn deinit(self: *@This(), context: Context) void {
            switch (self.bufferType) {
                .full, .byte, .unmanaged => {
                    mem.freeAligned(context.allocator, self.alignment, self.stream.interface.buffer);
                    self.stream.interface.buffer = undefined;
                },
                .mmap => std.posix.munmap(@alignCast(self.stream.interface.buffer)),
            }
        }
    };
}

const _fs = @This();

// This method is job is not to actually do it this way, but to ensure it was done in this specific way
// the caller is responsible to make the invariants hold for this to work, as a matter of fact this will
// silently return in non-debug
pub fn readOnceAll(r: *std.Io.Reader) ![]const u8 {
    r.fillMore() catch |e| switch (e) {
        error.EndOfStream => return r.buffered(),
        error.ReadFailed => return e,
    };

    // force an extra syscall to fail and ensure we read everything in the first go on debug mode
    if (ergo.isDebug and r.bufferedLen() < r.buffer.len) {
        const len = r.bufferedLen();
        if (r.fill(r.buffer.len))
            std.debug.assert(false)
        else |e| switch (e) {
            error.EndOfStream => std.debug.assert(len == r.bufferedLen()),
            // possible on pid delete
            error.ReadFailed => {},
        }
    }

    return r.buffered();
}

pub const FileCursorError = error{
    FollowSymlinkDisabled,
};

pub const FileCursorConfig = struct {
    recursive: bool = true,
    followSymlink: bool = true,
    policy: Policy = r: {
        const p = DefaultFileCursorPolicy{};
        break :r .{ .data = @ptrCast(@constCast(&p)), .interface = &.{
            .open = &DefaultFileCursorPolicy.open,
            .enter = &DefaultFileCursorPolicy.enter,
        } };
    },

    // This is mirrored to avoid the sentinel
    pub const PolicyEntryData = struct {
        dir: std.Io.Dir,
        basename: []const u8,
        path: []const u8,
        kind: File.Kind,
        inode: File.INode,
    };

    pub const PolicyEntry = union(enum) {
        // This means it's not yet handled by the walker
        preWalkerEntry: PolicyEntryData,
        // This means we are inside the walker (recurisve)
        entry: rDir.Walker.Entry,
        stdin,
        stdout,
        stderr,
    };

    pub const PolicyVTable = struct {
        open: *const fn (*anyopaque, PolicyEntry) bool,
        enter: *const fn (*anyopaque, PolicyEntry) bool,
    };

    // Policy checks happen at FileCursor.path resolution
    // Once that's covered, they also happen after entry resolution
    // which, means the path will get tracked through symlink (if toggled)
    // so this isn't a visitor mechanism, this is a matching path mechanism for the
    // return given by FileCursor.next
    pub const Policy = struct {
        data: *anyopaque,
        interface: *const PolicyVTable,
    };

    pub const DefaultFileCursorPolicy = struct {
        pub fn open(_: *anyopaque, _: PolicyEntry) bool {
            return true;
        }

        pub fn enter(_: *anyopaque, _: PolicyEntry) bool {
            return true;
        }
    };
};

pub fn FileCursor(mode: Mode) type {
    return struct {
        paths: []const []const u8,
        i: usize = 0,
        hasTrailingPath: bool = false,
        cursor: ?rDir.Walker = null,
        currentEntry: ?rDir.Walker.Entry = null,
        config: FileCursorConfig = .{},

        pub fn init(paths: []const []const u8) @This() {
            return .{ .paths = paths };
        }

        pub fn initWithConfig(paths: []const []const u8, config: FileCursorConfig) @This() {
            return .{
                .paths = paths,
                .config = config,
            };
        }

        // Current path is guaranteed to be at the path that failed in case you query it
        // after an error return
        pub fn currentPath(self: @This()) ?[]const u8 {
            if (self.i < 1 or self.i > self.paths.len) return null;

            if (self.currentEntry) |entry|
                return entry.path;

            const path = self.paths[self.i - 1];
            return if (self.hasTrailingPath) path[0 .. path.len - 1] else path;
        }

        pub fn next(self: *@This(), context: Context) !?FileStream(mode) {
            return try self.nextWithConfig(
                context,
                .{},
                FileStream(mode).DefaultBufferType,
                defaultBufferConfig(mode),
            );
        }

        pub fn nextUnmanaged(self: *@This(), context: Context) !?FileStream(mode) {
            return self.nextWithConfig(
                context,
                .{},
                .unmanaged,
                defaultBufferConfig(mode),
            );
        }

        fn pickPath(self: *@This()) !?[]const u8 {
            if (self.i >= self.paths.len) return null;
            const path = self.paths[self.i];
            self.i += 1;

            self.hasTrailingPath = path[path.len - 1] == '/';
            return if (self.hasTrailingPath) path[0 .. path.len - 1] else path;
        }

        // TODO: inherit visitor for newer walkers to keep track of symlinks
        // NOTE: when mulitple paths are given and one is on top of the other, even with the fix above
        // nextWithConfig will evalue the same files again, I dont know if I care about it tbh, the cost
        // to fix this case is big
        pub fn nextWithConfig(
            self: *@This(),
            context: Context,
            openConfig: OpenConfig,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
        ) !?FileStream(mode) {
            pathLoop: while (true) {
                if (self.cursor) |*cursor| {
                    while (true) {
                        if (cursor.next(context.io) catch |e| {
                            switch (e) {
                                // Review all errors for better propagation picks
                                error.OutOfMemory => return e,
                                else => continue,
                            }
                        }) |entry| {
                            switch (entry.kind) {
                                .sym_link, .directory => continue,
                                else => {
                                    if (!self.config.policy.interface.open(self.config.policy.data, .{ .entry = entry })) continue;

                                    self.currentEntry = entry;
                                    const file = try entry.dir.openFile(context.io, entry.basename, .{});
                                    errdefer file.close(context.io);

                                    return try .openStreamWithConfig(
                                        context,
                                        file,
                                        openConfig,
                                        bufferType,
                                        bufferConfig,
                                        null,
                                    );
                                },
                            }
                        } else {
                            self.cursor.?.deinit();
                            self.cursor = null;
                            self.currentEntry = null;
                            continue :pathLoop;
                        }
                    }
                }

                const path = try self.pickPath() orelse {
                    self.i += 1;
                    return null;
                };
                // In all cases, even if there's an error, we move to i += 1
                // the only case where we dont do that is when we are running the cursor loop at the beginning
                // This means any failure we move forward already
                if (std.mem.eql(u8, "-", path)) {
                    @branchHint(.unlikely);

                    if (!self.config.policy.interface.open(self.config.policy.data, .stdin)) continue;

                    return try .openStreamWithConfig(
                        context,
                        std.Io.File.stdin(),
                        openConfig,
                        bufferType,
                        bufferConfig,
                        null,
                    );
                }

                const cwd = std.Io.Dir.cwd();
                const maybeFile = try cwd.openFile(context.io, path, openConfig.toOpenFileOptions(.read));
                const stat = maybeFile.stat(context.io) catch |e| {
                    maybeFile.close(context.io);
                    return e;
                };
                switch (stat.kind) {
                    .directory, .sym_link => {
                        if (self.config.recursive) {
                            if (stat.kind == .sym_link and !self.config.followSymlink) {
                                @branchHint(.unlikely);
                                return FileCursorError.FollowSymlinkDisabled;
                            }
                            maybeFile.close(context.io);

                            if (!self.config.policy.interface.enter(self.config.policy.data, .{
                                .preWalkerEntry = .{
                                    .dir = cwd,
                                    .basename = "",
                                    .path = path,
                                    .kind = stat.kind,
                                    .inode = stat.inode,
                                },
                            })) continue;

                            const dir = try cwd.openDir(context.io, path, .{ .iterate = true });
                            errdefer dir.close(context.io);

                            self.cursor = try rDir.walk(
                                context.io,
                                dir,
                                path,
                                context.allocator,
                                self.config.followSymlink,
                                self.config.policy,
                            );

                            continue :pathLoop;
                        } else {
                            maybeFile.close(context.io);
                            return error.FileCannotBeOpenedForRead;
                        }
                    },
                    else => {
                        if (!self.config.policy.interface.open(self.config.policy.data, .{
                            .preWalkerEntry = .{
                                .dir = cwd,
                                .basename = "",
                                .path = path,
                                .kind = stat.kind,
                                .inode = stat.inode,
                            },
                        })) {
                            maybeFile.close(context.io);
                            continue;
                        }

                        errdefer maybeFile.close(context.io);
                        return try .openStreamWithConfig(
                            context,
                            maybeFile,
                            openConfig,
                            bufferType,
                            bufferConfig,
                            stat,
                        );
                    },
                }
            }
        }

        pub fn deinit(self: *@This()) void {
            if (self.cursor) |*cursor| {
                cursor.deinit();
                self.cursor = null;
            }
            self.currentEntry = null;
        }
    };
}

pub const Utf8Cursor = struct {
    reader: *std.Io.Reader,

    pub const NextError = error{
        BadUtf8,
    };

    pub fn next(self: *@This()) !?u21 {
        const r = self.reader;

        if (r.buffered().len == 0) {
            r.fill(1) catch |e| switch (e) {
                error.EndOfStream => return null,
                error.ReadFailed => return e,
            };
        }

        const buf = r.buffered();
        const lead = buf[0];

        const len = std.unicode.utf8ByteSequenceLength(lead) catch {
            r.toss(1);
            return error.BadUtf8;
        };

        if (len == 1) {
            r.toss(1);
            return @intCast(lead);
        }

        var seq: [4]u8 = undefined;
        seq[0] = lead;
        r.toss(1);

        for (1..len) |i| {
            if (r.bufferedLen() == 0) {
                r.fill(1) catch |e| switch (e) {
                    error.EndOfStream => return error.BadUtf8,
                    error.ReadFailed => return e,
                };
            }

            seq[i] = r.buffered()[0];
            r.toss(1);
        }

        const codepoint = std.unicode.utf8Decode(seq[0..len]) catch {
            return error.BadUtf8;
        };

        return codepoint;
    }
};

const testing = std.testing;

test "utf8 cursor" {
    var reader: std.Io.Reader = .fixed(@as([]const u8, ([_]u8{
        'A',
        0x7F,
        0x80,
        // 2b
        0xC2,
        0x80,
        // -
        0xDF,
        0xBF,
        // failures
        0xC0,
        0xAF,
        // -
        0xC0,
        0x80,
        // 3b
        0xE0,
        0xA0,
        0x80,
        // -
        0xED,
        0x9F,
        0xBF,
        // -
        0xEE,
        0x80,
        0x80,
        // failures
        0xE0,
        0x9F,
        0xBF,
        // 4b
        0xF0,
        0x90,
        0x80,
        0x80,
        // -
        0xF4,
        0x8F,
        0xBF,
        0xBF,
        // -
        0xF0,
        0x9F,
        0x92,
        0xA9,
        // failures
        0xF0,
        0x8F,
        0xBF,
        0xBF,
    })[0..]));
    var cursor: Utf8Cursor = .{ .reader = &reader };

    try testing.expectEqual('A', try cursor.next());
    try testing.expectEqual(0x7F, try cursor.next());
    try testing.expectError(error.BadUtf8, cursor.next());
    try testing.expectEqual(0x80, cursor.next());
    try testing.expectEqual(0x07FF, cursor.next());
    try testing.expectError(error.BadUtf8, cursor.next());
    try testing.expectError(error.BadUtf8, cursor.next());
    try testing.expectEqual(0x0800, cursor.next());
    try testing.expectEqual(0xD7FF, cursor.next());
    try testing.expectEqual(0xE000, cursor.next());
    try testing.expectError(error.BadUtf8, cursor.next());
    try testing.expectEqual(0x010000, cursor.next());
    try testing.expectEqual(0x10FFFF, cursor.next());
    try testing.expectEqual('💩', cursor.next());
    try testing.expectError(error.BadUtf8, cursor.next());
    try testing.expectEqual(null, cursor.next());
}

fn fuzzMakeFile(
    maxSize: usize,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: Allocator,
    name: []const u8,
    rng: std.Random,
) !struct { std.Io.File, []const u8, usize } {
    const f = try dir.createFile(io, name, .{ .read = true });
    errdefer f.close(io);

    const size = rng.intRangeAtMost(usize, 0, maxSize);
    var buf: [BufferConfig.defaultWriterConfig.fileBufferSize]u8 = undefined;

    var fw = f.writer(io, &buf);
    const w = &fw.interface;

    var content: []u8 = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const inputMod: u8 = 94;
    const inputBase: u8 = 33;

    var total: usize = 0;
    var lines: usize = 0;
    while (total < size) {
        const lineSize = rng.intRangeAtMost(usize, 0, size - total - 1);
        const unrollFactor = 8;

        var reminder = lineSize;
        if (std.simd.suggestVectorLength(u8)) |VLen| {
            const Vec = @Vector(VLen, u8);
            const base: Vec = @splat(inputBase);
            const mod: Vec = @splat(inputMod);

            var bufRng: [VLen]u8 = undefined;

            while (reminder >= VLen) : (reminder -= VLen) {
                rng.bytes(&bufRng);

                const selected: Vec = @as(Vec, bufRng) % mod + base;

                const offset = reminder - VLen;
                @as(*[VLen]u8, content[total + offset ..][0..VLen]).* = selected;
            }
        }
        var bufRng: [unrollFactor]u8 = undefined;
        while (reminder >= unrollFactor) : (reminder -= unrollFactor) {
            rng.bytes(&bufRng);
            inline for (0..unrollFactor) |i| {
                content[total + reminder - i - 1] = bufRng[i] % inputMod + inputBase;
            }
        }

        rng.bytes(&bufRng);
        for (0..reminder) |i| {
            content[total + reminder - i - 1] = bufRng[i] % inputMod + inputBase;
        }

        content[total + lineSize] = '\n';
        total += lineSize + 1;
        lines += 1;
    }

    try w.writeAll(content);
    try w.flush();

    const stat = try f.stat(testing.io);
    try testing.expectEqual(size, stat.size);

    return .{ f, content, lines };
}

test "fuzz readFileRetained" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    var buf: [@sizeOf(u64)]u8 = undefined;
    std.Io.random(testing.io, &buf);
    var prng = std.Random.DefaultPrng.init(@bitCast(buf));

    // var prng = std.Random.DefaultPrng.init(0x777A);
    const rng = prng.random();

    for (0..10) |i| {
        var nameBuf: [64]u8 = undefined;
        const fName = try std.fmt.bufPrint(&nameBuf, "fuzz{d}", .{i});

        const f, const expected, _ = try fuzzMakeFile(
            @as(usize, (1 << 20)) + rng.intRangeAtMost(usize, 1, std.math.maxInt(u16) - 1),
            tmpDir.dir,
            testing.io,
            testing.allocator,
            fName,
            rng,
        );
        defer f.close(testing.io);
        defer testing.allocator.free(expected);

        var fs = try FileStream(.read).openStreamWithConfig(
            .{ .io = testing.io, .allocator = testing.allocator },
            f,
            .{},
            .unmanaged,
            .defaultReaderConfig,
            null,
        );

        const alignment: std.mem.Alignment = comptime .fromByteUnits(std.atomic.cache_line);
        var arr: std.ArrayListAligned(u8, alignment) = try .initCapacity(testing.allocator, rng.intRangeAtMost(
            usize,
            1,
            4096,
        ));
        defer arr.deinit(testing.allocator);

        fs.setBuffer(alignment, arr.allocatedSlice());
        const content = try fs.readFileRetained(testing.allocator, &arr);

        try testing.expectEqualStrings(expected, content);
    }
}

test "readFileRetained tiny initial capacity" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    for (1..5) |capacity| {
        var nameBuf: [64]u8 = undefined;
        const fName = try std.fmt.bufPrint(&nameBuf, "tiny{d}", .{capacity});

        const expect = "0123456789abcdef";
        const f = try makeFile(tmpDir.dir, testing.io, fName, &.{expect});
        defer f.close(testing.io);

        var fs = try FileStream(.read).openStreamWithConfig(
            .{ .io = testing.io, .allocator = testing.allocator },
            f,
            .{},
            .unmanaged,
            .defaultReaderConfig,
            null,
        );

        const alignment: std.mem.Alignment = comptime .fromByteUnits(std.atomic.cache_line);
        var arr: std.ArrayListAligned(u8, alignment) = try .initCapacity(testing.allocator, capacity);
        defer arr.deinit(testing.allocator);

        fs.setBuffer(alignment, arr.allocatedSlice());
        const content = try fs.readFileRetained(testing.allocator, &arr);

        try testing.expectEqualStrings(expect, content);
    }
}

test "readLineRetained stat-known EOF exact fit doesnt expand" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const Case = struct {
        content: []const u8,
        lines: []const []const u8,
    };

    for (@as([]const Case, &.{
        .{ .content = "a\nb\n", .lines = &.{ "a\n", "b\n" } },
        .{ .content = "a\nbc", .lines = &.{ "a\n", "bc" } },
    }), 0..) |case, i| {
        var nameBuf: [64]u8 = undefined;
        const fName = try std.fmt.bufPrint(&nameBuf, "exact{d}", .{i});

        const f = try makeFile(tmpDir.dir, testing.io, fName, case.lines);
        defer f.close(testing.io);

        var fs = try FileStream(.read).openStreamWithConfig(
            .{ .io = testing.io, .allocator = testing.allocator },
            f,
            .{},
            .unmanaged,
            .defaultReaderConfig,
            null,
        );

        const alignment: std.mem.Alignment = comptime .fromByteUnits(std.atomic.cache_line);
        var arr: std.ArrayListAligned(u8, alignment) = try .initCapacity(testing.allocator, case.content.len);
        defer arr.deinit(testing.allocator);
        const capacityBefore = arr.capacity;

        fs.setBuffer(alignment, arr.allocatedSlice());

        for (case.lines) |line| {
            try testing.expectEqualStrings(line, (try fs.readLineRetained(testing.allocator, &arr)).?);
        }
        try testing.expectEqual(null, try fs.readLineRetained(testing.allocator, &arr));
        try testing.expectEqual(capacityBefore, arr.capacity);
    }
}

test "readFileRetained stat-known EOF exact fit doesnt expand" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const expect = "0123456789abcdef";
    const f = try makeFile(tmpDir.dir, testing.io, "exactFitFile", &.{expect});
    defer f.close(testing.io);

    var fs = try FileStream(.read).openStreamWithConfig(
        .{ .io = testing.io, .allocator = testing.allocator },
        f,
        .{},
        .unmanaged,
        .defaultReaderConfig,
        null,
    );

    const alignment: std.mem.Alignment = comptime .fromByteUnits(std.atomic.cache_line);
    var arr: std.ArrayListAligned(u8, alignment) = try .initCapacity(testing.allocator, expect.len);
    defer arr.deinit(testing.allocator);
    const capacityBefore = arr.capacity;

    fs.setBuffer(alignment, arr.allocatedSlice());
    const content = try fs.readFileRetained(testing.allocator, &arr);

    try testing.expectEqualStrings(expect, content);
    try testing.expectEqual(capacityBefore, arr.capacity);
}

test "fuzz readLineRetained" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    var buf: [@sizeOf(u64)]u8 = undefined;
    std.Io.random(testing.io, &buf);
    var prng = std.Random.DefaultPrng.init(@bitCast(buf));

    // var prng = std.Random.DefaultPrng.init(0x777A);
    const rng = prng.random();

    for (0..10) |i| {
        var nameBuf: [64]u8 = undefined;
        const fName = try std.fmt.bufPrint(&nameBuf, "fuzz{d}", .{i});

        const f, const expected, const expectedLen = try fuzzMakeFile(
            @as(usize, (1 << 20)) + rng.intRangeAtMost(usize, 1, std.math.maxInt(u16) - 1),
            tmpDir.dir,
            testing.io,
            testing.allocator,
            fName,
            rng,
        );
        defer f.close(testing.io);
        defer testing.allocator.free(expected);

        var fs = try FileStream(.read).openStreamWithConfig(
            .{ .io = testing.io, .allocator = testing.allocator },
            f,
            .{},
            .unmanaged,
            .defaultReaderConfig,
            null,
        );

        const alignment: std.mem.Alignment = comptime .fromByteUnits(std.atomic.cache_line);
        var arr: std.ArrayListAligned(u8, alignment) = try .initCapacity(testing.allocator, rng.intRangeAtMost(
            usize,
            1,
            4096,
        ));
        defer arr.deinit(testing.allocator);

        fs.setBuffer(alignment, arr.allocatedSlice());

        var it = std.mem.splitScalar(u8, expected, '\n');
        var actualLen: usize = 0;
        while (it.next()) |line| {
            if (try fs.readLineRetained(testing.allocator, &arr)) |actualLine| {
                try testing.expectEqualStrings(line, actualLine[0..actualLine.len -| 1]);
                actualLen += 1;
            }
        }
        try testing.expectEqual(expectedLen, actualLen);
    }
}

fn makeFile(
    dir: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    content: []const []const u8,
) !std.Io.File {
    const f = try dir.createFile(io, name, .{ .read = true });
    errdefer f.close(io);

    var buf: [BufferConfig.defaultWriterConfig.fileBufferSize]u8 = undefined;

    var fw = f.writer(testing.io, &buf);
    const w = &fw.interface;

    for (content) |line| {
        try w.writeAll(line);
    }
    try w.flush();

    return f;
}

fn randomName(allocator: Allocator) ![]const u8 {
    var prng = std.Random.DefaultPrng.init(0x8A11);
    const random = prng.random();
    var buf: [16]u8 = undefined;
    random.bytes(&buf);

    for (0..buf.len) |i| {
        buf[i] = buf[i] % (122 - 97) + 97;
    }

    const name = try allocator.alloc(u8, buf.len);
    @memcpy(name, buf[0..]);
    return name;
}

fn makeFileAndExpect(dir: std.Io.Dir, bufSize: usize, expect: []const []const u8, expectLen: usize) !void {
    const name = try randomName(testing.allocator);
    defer testing.allocator.free(name);

    const f = try makeFile(
        dir,
        testing.io,
        name,
        expect,
    );
    defer f.close(testing.io);

    const context: Context = .{ .io = testing.io, .allocator = testing.allocator };
    var fs = try FileStream(.read).openStreamWithConfig(
        context,
        f,
        .{},
        .unmanaged,
        .defaultReaderConfig,
        null,
    );

    const alignment: std.mem.Alignment = comptime .fromByteUnits(std.atomic.cache_line);
    var arr: std.ArrayListAligned(u8, alignment) = try .initCapacity(
        testing.allocator,
        bufSize,
    );
    defer arr.deinit(testing.allocator);

    fs.setBuffer(alignment, arr.allocatedSlice());

    var actualLen: usize = 0;
    while (try fs.readLineRetained(testing.allocator, &arr)) |line| : (actualLen += 1) {
        if (actualLen >= expectLen) try testing.expect(false);
        try testing.expectEqualStrings(expect[actualLen], line);
    }
    try testing.expectEqual(expectLen, actualLen);
}

test "readLineRetained boundaries" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    var bufSize: usize = 1;
    for (0..10) |i| {
        try makeFileAndExpect(tmpDir.dir, bufSize, &.{
            "asdb\n",
            "asd\n",
        }, 2);

        try makeFileAndExpect(tmpDir.dir, bufSize, &.{
            "asdb\n",
            "asd",
        }, 2);

        try makeFileAndExpect(tmpDir.dir, bufSize, &.{
            "\n",
            "a",
        }, 2);

        try makeFileAndExpect(tmpDir.dir, bufSize, &.{"a"}, 1);
        try makeFileAndExpect(tmpDir.dir, bufSize, &.{""}, 0);
        try makeFileAndExpect(tmpDir.dir, bufSize, &.{"\n"}, 1);

        bufSize = @as(usize, 1) << @as(u6, @intCast(i));
    }
}
