const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch.isWasm();

// Match Zig 0.16's std.start allocator selection for custom entrypoints.
const use_debug_allocator = !is_wasm and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe => !builtin.link_libc,
    .ReleaseFast, .ReleaseSmall => !builtin.link_libc and builtin.single_threaded,
};

debug_allocator: std.heap.DebugAllocator(.{}) = .init,

pub fn allocator(self: *@This()) std.mem.Allocator {
    return if (use_debug_allocator)
        self.debug_allocator.allocator()
    else if (builtin.link_libc)
        std.heap.c_allocator
    else if (is_wasm)
        std.heap.wasm_allocator
    else if (!builtin.single_threaded)
        std.heap.smp_allocator
    else
        comptime unreachable;
}

pub fn deinit(self: *@This()) void {
    if (use_debug_allocator and self.debug_allocator.deinit() != .ok) {
        @panic("Memory leak on exit!");
    }
}
