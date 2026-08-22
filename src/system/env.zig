//! Kernel-wide environment variables.
//!
//! A small fixed KEY=VALUE table shared by everyone: the shell manages it via
//! set/unset/env and expands $KEY on its command line, and Win32 PE programs
//! read it through emulated GetEnvironmentVariableA. Storage is static — no
//! allocation, values are plain slices into this file's buffers.

pub const ENV_MAX: usize = 32;
pub const KEY_MAX: usize = 32;
pub const VAL_MAX: usize = 64;

const EntryData = struct {
    key: [KEY_MAX]u8 = undefined,
    key_len: usize = 0,
    value: [VAL_MAX]u8 = undefined,
    value_len: usize = 0,
    used: bool = false,
};

var store: [ENV_MAX]EntryData = undefined;

/// A borrowed key/value pair; valid until the next set/unset call.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Look up a variable by name.
pub fn get(key: []const u8) ?[]const u8 {
    for (&store) |*e| {
        if (e.used and eql(e.key[0..e.key_len], key)) {
            return e.value[0..e.value_len];
        }
    }
    return null;
}

/// Set or overwrite a variable. Returns false when the table is full.
pub fn set(key: []const u8, value: []const u8) bool {
    for (&store) |*e| {
        if (e.used and eql(e.key[0..e.key_len], key)) {
            return storeValue(e, key, value);
        }
    }
    for (&store) |*e| {
        if (!e.used) {
            e.used = true;
            return storeValue(e, key, value);
        }
    }
    return false;
}

/// Remove a variable, if present.
pub fn unset(key: []const u8) void {
    for (&store) |*e| {
        if (e.used and eql(e.key[0..e.key_len], key)) {
            e.used = false;
            return;
        }
    }
}

/// Indexed access for iteration: entries at index >= count() are unused.
pub fn maxEntries() usize {
    return ENV_MAX;
}

pub fn getAt(idx: usize) ?Entry {
    if (idx >= ENV_MAX) return null;
    const e = &store[idx];
    if (!e.used) return null;
    return .{ .key = e.key[0..e.key_len], .value = e.value[0..e.value_len] };
}

fn storeValue(e: *EntryData, key: []const u8, value: []const u8) bool {
    const klen = @min(key.len, KEY_MAX);
    const vlen = @min(value.len, VAL_MAX);
    @memcpy(e.key[0..klen], key[0..klen]);
    e.key_len = klen;
    @memcpy(e.value[0..vlen], value[0..vlen]);
    e.value_len = vlen;
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
