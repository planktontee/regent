const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;

// Mostly taken from std StackFallbackAllocator
pub fn PromotingSfba(comptime size: usize) type {
    return struct {
        const Self = @This();

        buffer: [size]u8,
        fallback_allocator: Allocator,
        fixed_buffer_allocator: FixedBufferAllocator,
        get_called: if (std.debug.runtime_safety) bool else void =
            if (std.debug.runtime_safety) false else {},

        /// This function both fetches a `Allocator` interface to this
        /// allocator *and* resets the internal buffer allocator.
        pub fn get(self: *Self) Allocator {
            if (std.debug.runtime_safety) {
                assert(!self.get_called); // `get` called multiple times; instead use `const allocator = stackFallback(N).get();`
                self.get_called = true;
            }
            self.fixed_buffer_allocator = FixedBufferAllocator.init(self.buffer[0..]);
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        /// Unlike most std allocators `StackFallbackAllocator` modifies
        /// its internal state before returning an implementation of
        /// the`Allocator` interface and therefore also doesn't use
        /// the usual `.allocator()` method.
        pub const allocator = @compileError("use 'const allocator = stackFallback(N).get();' instead");

        fn alloc(
            ctx: *anyopaque,
            len: usize,
            alignment: Alignment,
            ra: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return FixedBufferAllocator.alloc(&self.fixed_buffer_allocator, len, alignment, ra) orelse
                return self.fallback_allocator.rawAlloc(len, alignment, ra);
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            alignment: Alignment,
            new_len: usize,
            ra: usize,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
                if (new_len <= self.buffer.len - self.fixed_buffer_allocator.end_index) {
                    return FixedBufferAllocator.resize(&self.fixed_buffer_allocator, buf, alignment, new_len, ra);
                } else {
                    // NOTE: cannot resize as we are breaching stack size, it needs remap
                    return false;
                }
            } else {
                return self.fallback_allocator.rawResize(buf, alignment, new_len, ra);
            }
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
                if ((new_len - memory.len) < self.buffer.len - self.fixed_buffer_allocator.end_index) {
                    return FixedBufferAllocator.remap(&self.fixed_buffer_allocator, memory, alignment, new_len, return_address);
                } else {
                    const newBuff = self.fallback_allocator.rawAlloc(new_len, alignment, return_address) orelse return null;
                    @memcpy(newBuff[0..memory.len], memory);
                    FixedBufferAllocator.free(
                        &self.fixed_buffer_allocator,
                        memory,
                        alignment,
                        return_address,
                    );
                    return newBuff;
                }
            } else {
                return self.fallback_allocator.rawRemap(memory, alignment, new_len, return_address);
            }
        }

        fn free(
            ctx: *anyopaque,
            buf: []u8,
            alignment: Alignment,
            ra: usize,
        ) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
                return FixedBufferAllocator.free(&self.fixed_buffer_allocator, buf, alignment, ra);
            } else {
                return self.fallback_allocator.rawFree(buf, alignment, ra);
            }
        }
    };
}

pub fn stackFallback(comptime size: usize, fallback_allocator: Allocator) PromotingSfba(size) {
    return PromotingSfba(size){
        .buffer = undefined,
        .fallback_allocator = fallback_allocator,
        .fixed_buffer_allocator = undefined,
    };
}

test "StackFallbackAllocator" {
    {
        var stack_allocator = stackFallback(4096, std.testing.allocator);
        try std.heap.testAllocator(stack_allocator.get());
    }
    {
        var stack_allocator = stackFallback(4096, std.testing.allocator);
        try std.heap.testAllocatorAligned(stack_allocator.get());
    }
    {
        var stack_allocator = stackFallback(4096, std.testing.allocator);
        try std.heap.testAllocatorLargeAlignment(stack_allocator.get());
    }
    {
        var stack_allocator = stackFallback(4096, std.testing.allocator);
        try std.heap.testAllocatorAlignedShrink(stack_allocator.get());
    }
}
