//! HID report descriptor parsing, ported from the Linux kernel.
//!
//! The reference is `drivers/hid/hid-core.c`: the item parser
//! (`fetch_item`, `hid_parser_main`, `hid_parser_global`, `hid_parser_local`),
//! the report/field model (`hid_register_report`, `hid_add_field`), and the
//! bit-stream helpers (`__extract`, `snto32`).  The kernel keeps `struct
//! hid_report`/`struct hid_field` allocated per device; here the same data is
//! a fixed-size `Table`, because a report descriptor is small and the kernel
//! has no allocator in the input path.
//!
//! This file deliberately has no kernel dependencies.  `tools/test_hid_report.zig`
//! imports it directly, and the USB stack only supplies the bytes the device
//! returned for GET_DESCRIPTOR(Report).

pub const MAX_FIELDS: usize = 40;
pub const MAX_FIELD_USAGES: usize = 12;
pub const MAX_REPORTS: usize = 12;
pub const MAX_DESCRIPTOR_SIZE: usize = 512;

// HID usage pages (`include/linux/hid.h`, HID_UP_*).
pub const USAGE_PAGE_GENERIC_DESKTOP: u16 = 0x01;
pub const USAGE_PAGE_KEYBOARD: u16 = 0x07;
pub const USAGE_PAGE_LED: u16 = 0x08;
pub const USAGE_PAGE_BUTTON: u16 = 0x09;
pub const USAGE_PAGE_CONSUMER: u16 = 0x0C;

// Generic desktop usages (HID_GD_*).
pub const USAGE_GD_POINTER: u16 = 0x01;
pub const USAGE_GD_MOUSE: u16 = 0x02;
pub const USAGE_GD_KEYBOARD: u16 = 0x06;
pub const USAGE_GD_X: u16 = 0x30;
pub const USAGE_GD_Y: u16 = 0x31;
pub const USAGE_GD_WHEEL: u16 = 0x38;

// `struct hid_field` flags (HID_MAIN_ITEM_*).
pub const MAIN_ITEM_CONSTANT: u16 = 0x001;
pub const MAIN_ITEM_VARIABLE: u16 = 0x002;
pub const MAIN_ITEM_RELATIVE: u16 = 0x004;
pub const MAIN_ITEM_NULL_STATE: u16 = 0x040;

// Main item tags.
const MAIN_ITEM_INPUT: u4 = 8;
const MAIN_ITEM_OUTPUT: u4 = 9;
const MAIN_ITEM_COLLECTION: u4 = 10;
const MAIN_ITEM_FEATURE: u4 = 11;
const MAIN_ITEM_END_COLLECTION: u4 = 12;

// Global item tags.
const GLOBAL_USAGE_PAGE: u4 = 0;
const GLOBAL_LOGICAL_MINIMUM: u4 = 1;
const GLOBAL_LOGICAL_MAXIMUM: u4 = 2;
const GLOBAL_PHYSICAL_MINIMUM: u4 = 3;
const GLOBAL_PHYSICAL_MAXIMUM: u4 = 4;
const GLOBAL_UNIT_EXPONENT: u4 = 5;
const GLOBAL_UNIT: u4 = 6;
const GLOBAL_REPORT_SIZE: u4 = 7;
const GLOBAL_REPORT_ID: u4 = 8;
const GLOBAL_REPORT_COUNT: u4 = 9;
const GLOBAL_PUSH: u4 = 10;
const GLOBAL_POP: u4 = 11;

// Local item tags.
const LOCAL_USAGE: u4 = 0;
const LOCAL_USAGE_MINIMUM: u4 = 1;
const LOCAL_USAGE_MAXIMUM: u4 = 2;
const LOCAL_DELIMITER: u4 = 10;

pub const ReportType = enum(u8) {
    input = 1,
    output = 2,
    feature = 3,
};

pub const Usage = struct {
    page: u16 = 0,
    id: u16 = 0,

    pub fn equals(self: Usage, other: Usage) bool {
        return self.page == other.page and self.id == other.id;
    }

    pub fn hid(self: Usage) u32 {
        return (@as(u32, self.page) << 16) | self.id;
    }

    pub fn inPage(self: Usage, page: u16) bool {
        return self.page == page;
    }
};

pub const ReportInfo = struct {
    report_type: ReportType = .input,
    id: u8 = 0,
    bits: u32 = 0,

    pub fn len(self: ReportInfo) usize {
        return (self.bits + 7) / 8;
    }
};

/// One `struct hid_field` from `hid-core.c`.
pub const Field = struct {
    report_type: ReportType = .input,
    report_id: u8 = 0,
    /// Bit offset relative to the start of the report payload (that is,
    /// after the report ID byte when the report is numbered).
    bit_offset: u16 = 0,
    report_size: u8 = 0,
    report_count: u16 = 0,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
    flags: u16 = 0,
    /// Number of entries in `usages`.
    explicit_count: u8 = 0,
    /// True when the descriptor declared Usage Minimum/Usage Maximum.
    has_range: bool = false,
    usage_min: Usage = .{},
    usage_max: Usage = .{},
    usages: [MAX_FIELD_USAGES]Usage = @splat(.{}),

    pub fn isConstant(self: Field) bool {
        return (self.flags & MAIN_ITEM_CONSTANT) != 0;
    }

    pub fn isVariable(self: Field) bool {
        return (self.flags & MAIN_ITEM_VARIABLE) != 0;
    }

    pub fn isRelative(self: Field) bool {
        return (self.flags & MAIN_ITEM_RELATIVE) != 0;
    }

    pub fn rangeCount(self: Field) u32 {
        if (!self.has_range) return 0;
        if (self.usage_min.page != self.usage_max.page) return 0;
        if (self.usage_max.id < self.usage_min.id) return 0;
        return @as(u32, self.usage_max.id) - @as(u32, self.usage_min.id) + 1;
    }

    /// `field->usage[i]`: explicit usages first, then the declared range,
    /// then the last usage repeated (Linux duplicates the last usage when the
    /// report count is larger than the usage list).
    pub fn usageAt(self: Field, index: u32) Usage {
        if (index < self.explicit_count) return self.usages[@intCast(index)];
        const offset = index - self.explicit_count;
        if (self.has_range and offset < self.rangeCount()) {
            return .{
                .page = self.usage_min.page,
                .id = @intCast(@as(u32, self.usage_min.id) + offset),
            };
        }
        if (self.explicit_count > 0) return self.usages[@as(usize, self.explicit_count) - 1];
        if (self.has_range) return self.usage_max;
        return .{};
    }

    /// The usage an array field's value names: `field->usage[value - logical_min]`.
    /// Returns null when the value is outside the logical range or outside
    /// the declared usage list (`hid_array_value_is_valid`).
    pub fn usageForValue(self: Field, value: i32) ?Usage {
        if (value < self.logical_min) return null;
        if (self.logical_max >= self.logical_min and value > self.logical_max) return null;
        const index: u32 = @intCast(value - self.logical_min);
        if (index < self.explicit_count) return self.usages[@intCast(index)];
        const offset = index - self.explicit_count;
        if (self.has_range and offset < self.rangeCount()) {
            return .{
                .page = self.usage_min.page,
                .id = @intCast(@as(u32, self.usage_min.id) + offset),
            };
        }
        return null;
    }

    /// Read this field's `index`-th value out of a report payload.
    /// `data` starts after the report ID byte (when the report is numbered).
    pub fn valueAt(self: Field, data: []const u8, index: u16) ?i32 {
        if (self.report_size == 0 or self.report_size > 32) return null;
        if (index >= self.report_count) return null;
        const bit_offset: u32 = @as(u32, self.bit_offset) +
            @as(u32, index) * @as(u32, self.report_size);
        const end_bit: u32 = bit_offset + self.report_size;
        if ((end_bit + 7) / 8 > data.len) return null;
        const raw = extractBits(data, bit_offset, self.report_size);
        if (self.logical_min < 0) return snto32(raw, self.report_size);
        return @intCast(raw);
    }

    /// Write a value back into an output report payload (`hid_output_field`).
    pub fn setValue(self: Field, data: []u8, index: u16, value: i32) void {
        if (self.report_size == 0 or self.report_size > 32) return;
        if (index >= self.report_count) return;
        const bit_offset: u32 = @as(u32, self.bit_offset) +
            @as(u32, index) * @as(u32, self.report_size);
        const end_bit: u32 = bit_offset + self.report_size;
        if ((end_bit + 7) / 8 > data.len) return;
        const encoded: u32 = if (self.logical_min < 0)
            @bitCast(value)
        else
            @intCast(value);
        implementBits(data, bit_offset, self.report_size, encoded);
    }
};

pub const Table = struct {
    fields: [MAX_FIELDS]Field = @splat(.{}),
    field_count: u16 = 0,
    reports: [MAX_REPORTS]ReportInfo = @splat(.{}),
    report_count: u8 = 0,
    /// Top-level application collection usage (Generic Desktop Keyboard,
    /// Mouse, ...).  This is how a HID interface is identified when the USB
    /// interface descriptor leaves the protocol at zero.
    application: Usage = .{},
    valid: bool = false,

    pub fn numbered(self: *const Table, report_type: ReportType) bool {
        for (self.reports[0..@as(usize, self.report_count)]) |report| {
            if (report.report_type == report_type and report.id != 0) return true;
        }
        return false;
    }

    pub fn findReport(self: *const Table, report_type: ReportType, id: u8) ?*const ReportInfo {
        for (self.reports[0..@as(usize, self.report_count)]) |*report| {
            if (report.report_type == report_type and report.id == id) return report;
        }
        return null;
    }

    pub fn hasInputReport(self: *const Table, id: u8) bool {
        var i: usize = 0;
        while (i < @as(usize, self.field_count)) : (i += 1) {
            const field = &self.fields[i];
            if (field.report_type == .input and field.report_id == id) return true;
        }
        return false;
    }

    pub fn kind(self: *const Table) ?Kind {
        // The usages in the fields decide, not only the application
        // collection: a composite receiver has one keyboard and one mouse
        // top-level collection, and the keyboard half must still win so
        // that the LEDs and the key translation are set up.
        var keyboard = false;
        var mouse_axes = false;
        if (self.application.page == USAGE_PAGE_GENERIC_DESKTOP) {
            switch (self.application.id) {
                USAGE_GD_KEYBOARD => keyboard = true,
                USAGE_GD_MOUSE, USAGE_GD_POINTER => mouse_axes = true,
                else => {},
            }
        }

        for (self.fields[0..@as(usize, self.field_count)]) |field| {
            var i: u32 = 0;
            while (i < field.report_count) : (i += 1) {
                const usage = field.usageAt(i);
                if (usage.page == USAGE_PAGE_KEYBOARD) keyboard = true;
                if (usage.page == USAGE_PAGE_GENERIC_DESKTOP and
                    (usage.id == USAGE_GD_X or usage.id == USAGE_GD_Y)) mouse_axes = true;
            }
        }
        if (keyboard) return .keyboard;
        if (mouse_axes) return .mouse;
        return null;
    }
};

pub const Kind = enum { keyboard, mouse };

pub const ParseError = error{
    Empty,
    Truncated,
    TooManyFields,
    TooManyReports,
    GlobalStackOverflow,
    GlobalStackUnderflow,
    InvalidReportSize,
    InvalidReportCount,
    InvalidReportId,
    InvalidLogicalRange,
    UnbalancedCollection,
    UnbalancedDelimiter,
    ReportTooLong,
};

const Global = struct {
    usage_page: u16 = 0,
    logical_minimum: i32 = 0,
    logical_maximum: i32 = 0,
    physical_minimum: i32 = 0,
    physical_maximum: i32 = 0,
    unit_exponent: i32 = 0,
    unit: u32 = 0,
    report_id: u8 = 0,
    report_size: u16 = 0,
    report_count: u16 = 0,
};

const Local = struct {
    usages: [MAX_FIELD_USAGES]Usage = @splat(.{}),
    usage_count: u8 = 0,
    usage_min: Usage = .{},
    usage_max: Usage = .{},
    has_min: bool = false,
    has_range: bool = false,
    delimiter_depth: u8 = 0,
    delimiter_branch: u8 = 0,

    fn reset(self: *Local) void {
        self.* = .{};
    }
};

const Parser = struct {
    table: Table = .{},
    global: Global = .{},
    global_stack: [4]Global = @splat(.{}),
    global_stack_top: usize = 0,
    local: Local = .{},
    collection_depth: u16 = 0,

    fn addUsage(self: *Parser, usage: Usage) void {
        // A report descriptor with more explicit usages than the table can
        // hold is rare; keeping the first ones is enough for keyboard and
        // mouse descriptors, and Linux itself caps this at HID_MAX_USAGES.
        if (@as(usize, self.local.usage_count) >= MAX_FIELD_USAGES) return;
        self.local.usages[self.local.usage_count] = usage;
        self.local.usage_count += 1;
    }

    fn reportInfo(self: *Parser, report_type: ReportType, id: u8) ParseError!*ReportInfo {
        for (self.table.reports[0..@as(usize, self.table.report_count)]) |*report| {
            if (report.report_type == report_type and report.id == id) return report;
        }
        if (self.table.report_count >= MAX_REPORTS) return error.TooManyReports;
        const report = &self.table.reports[@as(usize, self.table.report_count)];
        report.* = .{ .report_type = report_type, .id = id, .bits = 0 };
        self.table.report_count += 1;
        return report;
    }

    fn addField(self: *Parser, report_type: ReportType, flags: u16) ParseError!void {
        const report = try self.reportInfo(report_type, self.global.report_id);

        // `hid_add_field`: validate the logical range before anything else.
        if ((self.global.logical_minimum < 0 and
            self.global.logical_maximum < self.global.logical_minimum) or
            (self.global.logical_minimum >= 0 and
                @as(u32, @bitCast(self.global.logical_maximum)) <
                    @as(u32, @bitCast(self.global.logical_minimum))))
        {
            return error.InvalidLogicalRange;
        }

        const field_bits: u32 = @as(u32, self.global.report_size) *
            @as(u32, self.global.report_count);
        const offset = report.bits;
        if (offset + field_bits > 0xFFFF) return error.ReportTooLong;
        report.bits += field_bits;

        // Padding fields advance the report but have no usages.
        if (self.local.usage_count == 0 and !self.local.has_range) return;

        if (self.table.field_count >= MAX_FIELDS) return error.TooManyFields;

        const field = &self.table.fields[@as(usize, self.table.field_count)];
        field.* = .{
            .report_type = report_type,
            .report_id = self.global.report_id,
            .bit_offset = @intCast(offset),
            .report_size = @intCast(self.global.report_size),
            .report_count = self.global.report_count,
            .logical_min = self.global.logical_minimum,
            .logical_max = self.global.logical_maximum,
            .flags = flags,
            .explicit_count = self.local.usage_count,
            .has_range = self.local.has_range,
            .usage_min = self.local.usage_min,
            .usage_max = self.local.usage_max,
            .usages = self.local.usages,
        };
        self.table.field_count += 1;
    }

    fn mainItem(self: *Parser, tag: u4, data: u32) ParseError!void {
        switch (tag) {
            MAIN_ITEM_INPUT => try self.addField(.input, @intCast(data & 0x1FF)),
            MAIN_ITEM_OUTPUT => try self.addField(.output, @intCast(data & 0x1FF)),
            MAIN_ITEM_FEATURE => try self.addField(.feature, @intCast(data & 0x1FF)),
            MAIN_ITEM_COLLECTION => {
                if (self.collection_depth == 0) {
                    const usage = self.local.usages[0];
                    if (self.local.usage_count > 0) self.table.application = usage;
                }
                self.collection_depth += 1;
            },
            MAIN_ITEM_END_COLLECTION => {
                if (self.collection_depth == 0) return error.UnbalancedCollection;
                self.collection_depth -= 1;
            },
            else => {},
        }
        self.local.reset();
    }

    fn globalItem(self: *Parser, tag: u4, size: usize, data: u32) ParseError!void {
        switch (tag) {
            GLOBAL_USAGE_PAGE => self.global.usage_page = @truncate(data),
            GLOBAL_LOGICAL_MINIMUM => self.global.logical_minimum = sdata(size, data),
            GLOBAL_LOGICAL_MAXIMUM => {
                if (self.global.logical_minimum < 0) {
                    self.global.logical_maximum = sdata(size, data);
                } else {
                    self.global.logical_maximum = @bitCast(data);
                }
            },
            GLOBAL_PHYSICAL_MINIMUM => self.global.physical_minimum = sdata(size, data),
            GLOBAL_PHYSICAL_MAXIMUM => {
                if (self.global.physical_minimum < 0) {
                    self.global.physical_maximum = sdata(size, data);
                } else {
                    self.global.physical_maximum = @bitCast(data);
                }
            },
            GLOBAL_UNIT_EXPONENT => {
                const raw = sdata(size, data);
                // HID 1.11 6.2.2.7 says a signed nibble; many devices send a
                // sign-extended value instead.  Linux accepts both.
                self.global.unit_exponent = if ((@as(u32, @bitCast(raw)) & 0xFFFFFFF0) == 0)
                    snto32(@bitCast(raw), 4)
                else
                    raw;
            },
            GLOBAL_UNIT => self.global.unit = data,
            GLOBAL_REPORT_SIZE => {
                if (data > 256) return error.InvalidReportSize;
                self.global.report_size = @intCast(data);
            },
            GLOBAL_REPORT_COUNT => {
                // The Linux parser accepts up to HID_MAX_USAGES (12288).
                // A keyboard or mouse never needs more than a few dozen,
                // and the report itself is limited to 64 bytes on this
                // transport, so reject descriptors that would make the
                // decoder walk a huge range.
                if (data > 512) return error.InvalidReportCount;
                self.global.report_count = @intCast(data);
            },
            GLOBAL_REPORT_ID => {
                if (data == 0 or data >= 256) return error.InvalidReportId;
                self.global.report_id = @intCast(data);
            },
            GLOBAL_PUSH => {
                if (self.global_stack_top >= self.global_stack.len) {
                    return error.GlobalStackOverflow;
                }
                self.global_stack[self.global_stack_top] = self.global;
                self.global_stack_top += 1;
            },
            GLOBAL_POP => {
                if (self.global_stack_top == 0) return error.GlobalStackUnderflow;
                self.global_stack_top -= 1;
                self.global = self.global_stack[self.global_stack_top];
            },
            else => {},
        }
    }

    fn localItem(self: *Parser, tag: u4, size: usize, data: u32) void {
        const usage = if (size == 4)
            Usage{ .page = @truncate(data >> 16), .id = @truncate(data) }
        else
            Usage{ .page = self.global.usage_page, .id = @truncate(data) };

        switch (tag) {
            LOCAL_USAGE => {
                if (self.local.delimiter_branch > 1) return;
                self.addUsage(usage);
            },
            LOCAL_USAGE_MINIMUM => {
                if (self.local.delimiter_branch > 1) return;
                self.local.usage_min = usage;
                self.local.has_min = true;
            },
            LOCAL_USAGE_MAXIMUM => {
                if (self.local.delimiter_branch > 1) return;
                if (self.local.has_min) {
                    self.local.usage_max = usage;
                    self.local.has_range = true;
                }
            },
            LOCAL_DELIMITER => {
                if (data != 0) {
                    if (self.local.delimiter_depth != 0) return;
                    self.local.delimiter_depth += 1;
                    self.local.delimiter_branch += 1;
                } else {
                    if (self.local.delimiter_depth > 0) self.local.delimiter_depth -= 1;
                }
            },
            else => {},
        }
    }
};

/// Parse a HID report descriptor exactly as `hid_open_report()` does, minus
/// collections that only affect driver binding.
pub fn parse(descriptor: []const u8) ParseError!Table {
    if (descriptor.len == 0) return error.Empty;

    var parser = Parser{};
    var pos: usize = 0;

    while (pos < descriptor.len) {
        const prefix = descriptor[pos];

        // A control transfer that asked for more bytes than the descriptor
        // holds comes back zero-padded.  A zero prefix is not a legal item,
        // so a run of zeros at an item boundary is padding.
        if (prefix == 0 and allZero(descriptor[pos..])) break;

        if (prefix == 0xFE) {
            // Long item: 0xFE, bDataSize, bLongItemTag, data...
            if (pos + 3 > descriptor.len) return error.Truncated;
            const data_size: usize = descriptor[pos + 1];
            if (pos + 3 + data_size > descriptor.len) return error.Truncated;
            pos += 3 + data_size;
            continue;
        }

        pos += 1;
        const size: usize = switch (prefix & 0x03) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 4,
        };
        if (pos + size > descriptor.len) return error.Truncated;

        var data: u32 = 0;
        switch (size) {
            1 => data = descriptor[pos],
            2 => data = @as(u32, descriptor[pos]) | (@as(u32, descriptor[pos + 1]) << 8),
            4 => data = @as(u32, descriptor[pos]) |
                (@as(u32, descriptor[pos + 1]) << 8) |
                (@as(u32, descriptor[pos + 2]) << 16) |
                (@as(u32, descriptor[pos + 3]) << 24),
            else => {},
        }
        pos += size;

        const item_type = (prefix >> 2) & 0x03;
        const tag: u4 = @truncate(prefix >> 4);
        switch (item_type) {
            0 => try parser.mainItem(tag, data),
            1 => try parser.globalItem(tag, size, data),
            2 => parser.localItem(tag, size, data),
            else => {},
        }
    }

    if (parser.collection_depth != 0) return error.UnbalancedCollection;
    if (parser.local.delimiter_depth != 0) return error.UnbalancedDelimiter;

    parser.table.valid = parser.table.field_count > 0;
    return parser.table;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// `item_sdata`: the item payload interpreted as a signed integer of its own
/// width.  This is what the kernel uses for Logical Minimum and Physical
/// Minimum.
fn sdata(size: usize, data: u32) i32 {
    return switch (size) {
        1 => @as(i32, @as(i8, @bitCast(@as(u8, @truncate(data))))),
        2 => @as(i32, @as(i16, @bitCast(@as(u16, @truncate(data))))),
        4 => @bitCast(data),
        else => 0,
    };
}

/// `snto32` from `hid-core.c`: sign-extend an n-bit value.
pub fn snto32(value: u32, n: u8) i32 {
    if (value == 0 or n == 0) return 0;
    const bits: u8 = @min(n, 32);
    if (bits == 32) return @bitCast(value);
    const sign_bit: u32 = @as(u32, 1) << @intCast(bits - 1);
    if ((value & sign_bit) != 0) {
        const extended = value | (~@as(u32, 0) << @intCast(bits));
        return @bitCast(extended);
    }
    return @intCast(value);
}

/// `__extract` from `hid-core.c`: read an n-bit little-endian bit field.
/// The caller has already checked that the field lies inside `data`.
pub fn extractBits(data: []const u8, offset: u32, n: u8) u32 {
    var result: u64 = 0;
    var done: u32 = 0;
    const total: u32 = n;

    while (done < total) {
        const absolute = offset + done;
        const byte_index: usize = absolute / 8;
        if (byte_index >= data.len) break;
        const bit_index: u3 = @intCast(absolute % 8);
        const available: u32 = 8 - @as(u32, bit_index);
        const take: u32 = @min(available, total - done);
        const mask: u8 = if (take == 8)
            0xFF
        else
            (@as(u8, 1) << @intCast(take)) - 1;
        const chunk: u64 = (@as(u64, data[byte_index]) >> bit_index) & mask;
        result |= chunk << @intCast(done);
        done += take;
    }

    const mask: u64 = if (total < 32) (@as(u64, 1) << @intCast(total)) - 1 else 0xFFFFFFFF;
    return @intCast(result & mask);
}

/// `__implement` from `hid-core.c`: write an n-bit little-endian bit field.
pub fn implementBits(data: []u8, offset: u32, n: u8, value: u32) void {
    var remaining: u32 = n;
    var bit_offset = offset;
    var shift: u32 = 0;

    while (remaining > 0) {
        const byte_index: usize = bit_offset / 8;
        if (byte_index >= data.len) return;
        const bit_index: u3 = @intCast(bit_offset % 8);
        const available: u32 = 8 - @as(u32, bit_index);
        const take: u32 = @min(available, remaining);
        const mask: u8 = if (take == 8)
            0xFF
        else
            (@as(u8, 1) << @intCast(take)) - 1;
        const chunk: u8 = @truncate(value >> @intCast(shift));
        data[byte_index] &= ~(mask << bit_index);
        data[byte_index] |= (chunk & mask) << bit_index;
        shift += take;
        remaining -= take;
        bit_offset += take;
    }
}
