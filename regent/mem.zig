const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;

// Mostly taken from std StackFallbackAllocator
pub const PromotingSfba = struct {
    fallback_allocator: Allocator,
    fixed_buffer_allocator: FixedBufferAllocator,

    pub fn allocator(self: *@This()) Allocator {
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

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
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
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
            if (new_len <= self.fixed_buffer_allocator.buffer.len - self.fixed_buffer_allocator.end_index) {
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
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.fixed_buffer_allocator.ownsPtr(memory.ptr)) {
            if ((new_len - memory.len) < self.fixed_buffer_allocator.buffer.len - self.fixed_buffer_allocator.end_index) {
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
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
            return FixedBufferAllocator.free(&self.fixed_buffer_allocator, buf, alignment, ra);
        } else {
            return self.fallback_allocator.rawFree(buf, alignment, ra);
        }
    }
};

pub fn stackFallback(buffer: []u8, fallback_allocator: Allocator) PromotingSfba {
    return .{
        .fallback_allocator = fallback_allocator,
        .fixed_buffer_allocator = .init(buffer),
    };
}

test "StackFallbackAllocator" {
    {
        var buffer: [4096]u8 = undefined;
        var stack_allocator = stackFallback(&buffer, std.testing.allocator);
        try std.heap.testAllocator(stack_allocator.allocator());
    }
    {
        var buffer: [4096]u8 = undefined;
        var stack_allocator = stackFallback(&buffer, std.testing.allocator);
        try std.heap.testAllocatorAligned(stack_allocator.allocator());
    }
    {
        var buffer: [4096]u8 = undefined;
        var stack_allocator = stackFallback(&buffer, std.testing.allocator);
        try std.heap.testAllocatorLargeAlignment(stack_allocator.allocator());
    }
    {
        var buffer: [4096]u8 = undefined;
        var stack_allocator = stackFallback(&buffer, std.testing.allocator);
        try std.heap.testAllocatorAlignedShrink(stack_allocator.allocator());
    }
}
