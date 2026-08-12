//! Access to user memory from kernel context.
//!
//! All of these run while the *current* CR3 is the task's own address space
//! (syscalls are entered from ring 3), so user pointers can be dereferenced
//! directly. What they add is a bounds check against the user address range, so
//! a bad pointer from a program returns EFAULT instead of letting a program read
//! or corrupt kernel memory through a kernel-mode access.

const task = @import("task.zig");

/// Highest address a user program may pass us. Everything above the user stack
/// belongs to the kernel identity map.
const USER_ADDR_MAX: u64 = 0x80000000;
/// The first page is never mapped for user code, so a null-ish pointer is caught.
const USER_ADDR_MIN: u64 = 0x1000;

pub fn validRange(addr: u64, len: u64) bool {
    if (len == 0) return true;
    if (addr < USER_ADDR_MIN) return false;
    const end = addr +% len;
    if (end < addr) return false; // overflow
    return end <= USER_ADDR_MAX;
}

pub fn userSlice(addr: u64, len: u64) ?[]u8 {
    if (!validRange(addr, len)) return null;
    if (len == 0) return &[_]u8{};
    const ptr: [*]u8 = @ptrFromInt(addr);
    return ptr[0..@intCast(len)];
}

pub fn userSliceConst(addr: u64, len: u64) ?[]const u8 {
    if (!validRange(addr, len)) return null;
    if (len == 0) return &[_]u8{};
    const ptr: [*]const u8 = @ptrFromInt(addr);
    return ptr[0..@intCast(len)];
}

/// Copy a NUL-terminated user string into `buf`, returning the slice without the
/// terminator. Fails on unterminated strings rather than reading past the buffer.
pub fn readCStr(addr: u64, buf: []u8) ?[]const u8 {
    if (!validRange(addr, 1)) return null;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (!validRange(addr + i, 1)) return null;
        const p: [*]const u8 = @ptrFromInt(addr + i);
        const ch = p[0];
        if (ch == 0) return buf[0..i];
        buf[i] = ch;
    }
    return null; // no terminator within buf.len
}

pub fn readU8(addr: u64) ?u8 {
    if (!validRange(addr, 1)) return null;
    const p: [*]const u8 = @ptrFromInt(addr);
    return p[0];
}

pub fn readU16(addr: u64) ?u16 {
    if (!validRange(addr, 2)) return null;
    const lo = readU8(addr) orelse return null;
    const hi = readU8(addr + 1) orelse return null;
    return @as(u16, lo) | (@as(u16, hi) << 8);
}

pub fn readU32(addr: u64) ?u32 {
    if (!validRange(addr, 4)) return null;
    const lo = readU16(addr) orelse return null;
    const hi = readU16(addr + 2) orelse return null;
    return @as(u32, lo) | (@as(u32, hi) << 16);
}

pub fn readU64(addr: u64) ?u64 {
    if (!validRange(addr, 8)) return null;
    const lo = readU32(addr) orelse return null;
    const hi = readU32(addr + 4) orelse return null;
    return @as(u64, lo) | (@as(u64, hi) << 32);
}

pub fn writeU8(addr: u64, value: u8) bool {
    if (!validRange(addr, 1)) return false;
    const p: [*]u8 = @ptrFromInt(addr);
    p[0] = value;
    return true;
}

pub fn writeU16(addr: u64, value: u16) bool {
    if (!validRange(addr, 2)) return false;
    _ = writeU8(addr, @intCast(value & 0xFF));
    _ = writeU8(addr + 1, @intCast((value >> 8) & 0xFF));
    return true;
}

pub fn writeU32(addr: u64, value: u32) bool {
    if (!validRange(addr, 4)) return false;
    var i: u64 = 0;
    while (i < 4) : (i += 1) {
        _ = writeU8(addr + i, @intCast((value >> @intCast(i * 8)) & 0xFF));
    }
    return true;
}

pub fn writeU64(addr: u64, value: u64) bool {
    if (!validRange(addr, 8)) return false;
    var i: u64 = 0;
    while (i < 8) : (i += 1) {
        _ = writeU8(addr + i, @intCast((value >> @intCast(i * 8)) & 0xFF));
    }
    return true;
}

pub fn writeBytes(addr: u64, src: []const u8) bool {
    const dst = userSlice(addr, src.len) orelse return false;
    @memcpy(dst, src);
    return true;
}

/// UTF-16LE copy for the Win32 personality's wide-string APIs.
pub fn writeUtf16(addr: u64, src: []const u8, max_chars: usize) ?usize {
    var i: usize = 0;
    while (i < src.len and i + 1 < max_chars) : (i += 1) {
        if (!writeU16(addr + i * 2, src[i])) return null;
    }
    if (!writeU16(addr + i * 2, 0)) return null;
    return i;
}
