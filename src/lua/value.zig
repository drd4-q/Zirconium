const std = @import("std");

pub const ValueType = enum {
    nil,
    boolean,
    number,
    string,
    table,
    function,
    native_fn,
    closure,
};

pub const Value = struct {
    type: ValueType = .nil,
    boolean_val: bool = false,
    number_val: f64 = 0,
    string_val: ?[]const u8 = null,
    table_val: ?*Table = null,
    closure_val: ?*Closure = null,
    native_fn_val: ?*const fn ([]Value) Value = null,

    pub fn nil() Value {
        return .{ .type = .nil };
    }

    pub fn fromBool(b: bool) Value {
        return .{ .type = .boolean, .boolean_val = b };
    }

    pub fn fromNumber(n: f64) Value {
        return .{ .type = .number, .number_val = n };
    }

    pub fn fromString(s: []const u8) Value {
        return .{ .type = .string, .string_val = s };
    }

    pub fn fromNativeFn(fn_ptr: *const fn ([]Value) Value) Value {
        return .{ .type = .native_fn, .native_fn_val = fn_ptr };
    }

    pub fn fromTable(t: *Table) Value {
        return .{ .type = .table, .table_val = t };
    }

    pub fn fromClosure(c: *Closure) Value {
        return .{ .type = .closure, .closure_val = c };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self.type) {
            .nil => false,
            .boolean => self.boolean_val,
            .number => self.number_val != 0,
            .string => {
                if (self.string_val) |str| {
                    return str.len > 0;
                }
                return false;
            },
            else => true,
        };
    }

    pub fn equals(self: Value, other: Value) bool {
        if (self.type != other.type) return false;
        return switch (self.type) {
            .nil => true,
            .boolean => self.boolean_val == other.boolean_val,
            .number => self.number_val == other.number_val,
            .string => blk: {
                if (self.string_val == null or other.string_val == null)
                    break :blk self.string_val == null and other.string_val == null;
                break :blk std.mem.eql(u8, self.string_val.?, other.string_val.?);
            },
            else => false,
        };
    }

    pub fn format(self: Value) void {
        switch (self.type) {
            .nil => {},
            .boolean => {},
            .number => {},
            .string => {},
            else => {},
        }
    }
};

pub const TableEntry = struct {
    key: Value = .{},
    value: Value = .{},
    next: ?*TableEntry = null,
};

pub const Table = struct {
    entries: ?*TableEntry = null,
    array: ?[]Value = null,
    array_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ?Table {
        _ = allocator;
        return .{};
    }

    pub fn get(self: *Table, key: Value) ?Value {
        var entry = self.entries;
        while (entry) |e| {
            if (e.key.equals(key)) return e.value;
            entry = e.next;
        }
        return null;
    }

    pub fn set(self: *Table, key: Value, value: Value, allocator: std.mem.Allocator) void {
        var entry = self.entries;
        while (entry) |e| {
            if (e.key.equals(key)) {
                e.value = value;
                return;
            }
            entry = e.next;
        }
        const new_entry = allocator.create(TableEntry) catch return;
        new_entry.key = key;
        new_entry.value = value;
        new_entry.next = self.entries;
        self.entries = new_entry;
    }
};

pub const Closure = struct {
    params: []const []const u8,
    body: []const u8, // source code of the body
    upvalues: []Value,
    env: ?*Table,
};
