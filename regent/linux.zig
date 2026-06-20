const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const linux = std.os.linux;
const fd_t = linux.fd_t;
const is_debug = builtin.mode == .Debug;

pub fn errnoBug(err: linux.E) Io.UnexpectedError {
    if (is_debug) std.debug.panic("programmer bug caused syscall error: {t}", .{err});
    return error.Unexpected;
}

pub fn kernVersionOrAbove(comptime major: usize, comptime minor: usize, comptime patch: usize) bool {
    const kern = builtin.os.version_range.linux.range.min;
    if (kern.major != major) return kern.major > major;
    if (kern.minor != minor) return kern.minor > minor;
    return kern.patch >= patch;
}

pub const FcntlError = error{
    PermissionDenied,
    ResourceTemporarilyUnavailable,
    BadFileDescriptor,
    UnsupportedOperation,
} || Io.UnexpectedError;

pub const FcntlGetFLError = FcntlError;

pub fn fcntlGetFL(_: Io, fd: fd_t) FcntlGetFLError!linux.O {
    const result = linux.fcntl(fd, linux.F.GETFL, 0);
    return switch (linux.errno(result)) {
        .SUCCESS => @bitCast(@as(u32, @intCast(result))),
        .ACCES => return error.PermissionDenied,
        .AGAIN => return error.ResourceTemporarilyUnavailable,
        .BADF => return error.BadFileDescriptor,
        .INVAL => return error.UnsupportedOperation,
        else => |err| return errnoBug(err),
    };
}

pub const FcntlSetFLError = error{
    OperationNotAllowed,
} || FcntlError;

pub fn fcntlSetFL(_: Io, fd: fd_t, arg: linux.O) FcntlSetFLError!void {
    const flags: u32 = @bitCast(arg);
    const result = linux.fcntl(fd, linux.F.SETFL, @intCast(flags));
    switch (linux.errno(result)) {
        .SUCCESS => return,
        .PERM => return error.OperationNotAllowed,
        .ACCES => return error.PermissionDenied,
        .AGAIN => return error.ResourceTemporarilyUnavailable,
        .BADF => return error.BadFileDescriptor,
        .INVAL => return error.UnsupportedOperation,
        else => |err| return errnoBug(err),
    }
}

pub const SetFdStatusFlagsError = FcntlGetFLError || FcntlSetFLError;

pub fn setFdStatusFlags(io: Io, fd: fd_t, targetFlags: linux.O) SetFdStatusFlagsError!void {
    const currentFlags: linux.O = try fcntlGetFL(io, fd);
    const mergedFlags = @as(u32, @bitCast(currentFlags)) | @as(u32, @bitCast(targetFlags));
    try fcntlSetFL(io, fd, @bitCast(mergedFlags));
}

pub const FcntlSetPipeSzError = error{
    SmalledThanBufferedResize,
    PipeSizeCannotBeExpanded,
} || FcntlError;

pub fn fcntlSetPipeSZ(_: Io, fd: fd_t, arg: usize) FcntlSetPipeSzError!void {
    const result = linux.fcntl(fd, linux.F.SETPIPE_SZ, arg);
    return switch (linux.errno(result)) {
        .SUCCESS => return,
        .BUSY => return error.SmalledThanBufferedResize,
        .PERM => return error.PipeSizeCannotBeExpanded,
        .ACCES => return error.PermissionDenied,
        .AGAIN => return error.ResourceTemporarilyUnavailable,
        .BADF => return error.BadFileDescriptor,
        .INVAL => return error.UnsupportedOperation,
        else => |err| return errnoBug(err),
    };
}

pub const FADVISE = enum(u3) {
    // Based on glibc
    NORMAL = 0,
    RANDOM = 1,
    SEQUENTIAL = 2,
    WILLNEED = 3,
    DONTNEED = 4,
    NOREUSE = 5,
};

pub const FAdviseError = error{
    BadFileDescriptor,
    AdvicePassedToPipe,
} || Io.UnexpectedError;

pub fn fadvise(_: Io, fd: fd_t, offset: usize, len: usize, advice: FADVISE) FAdviseError!void {
    const result = std.os.linux.fadvise(
        fd,
        @bitCast(offset),
        @bitCast(len),
        @intFromEnum(advice),
    );
    return switch (linux.errno(result)) {
        .SUCCESS => return,
        .BADF => return error.BadFileDescriptor,
        .INVAL => |err| return errnoBug(err),
        .SPIPE => return error.AdvicePassedToPipe,
        else => |err| return errnoBug(err),
    };
}
