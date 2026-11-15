//! The HID++ protocol: the wire format of Logitech's 2.4 GHz receivers.
//!
//! Ported from the Linux kernel's `drivers/hid/hid-logitech-hidpp.c`: the
//! report format, the feature (page) numbers and the functions.
//!
//! HID++ is how a Logitech receiver talks about the devices that are
//! paired with it.  A receiver is a USB device, but the keyboard or the
//! mouse behind it is not: the receiver forwards the HID++ reports and the
//! driver asks the receiver about the device it is interested in.
//!
//! There are two report formats:
//!
//!   * the short report (0x10), seven bytes, used by HID++ 1.0;
//!   * the long report (0x11), twenty bytes, used by HID++ 2.0.
//!
//! Both start with the report ID and the index of the device the report is
//! about, and both carry the feature index, the function and the
//! parameters.
//!
//! This file is free of kernel dependencies: it is the protocol, not the
//! transport, so `tools/test_hidpp.zig` can import it and check it on the
//! host.

/// The short report: the HID++ 1.0 format.
pub const REPORT_ID_SHORT: u8 = 0x10;
/// The long report: the HID++ 2.0 format.
pub const REPORT_ID_LONG: u8 = 0x11;

/// The size of a short report.
pub const SHORT_LENGTH: usize = 7;
/// The size of a long report.
pub const LONG_LENGTH: usize = 20;

/// The features (Linux calls them "pages"), from `HIDPP_PAGE_*`.
pub const Feature = struct {
    /// The root feature: the way to ask for the other features.
    pub const root: u16 = 0x0000;
    /// The feature set: the list of the features a device has.
    pub const feature_set: u16 = 0x0001;
    /// The device information.
    pub const device_info: u16 = 0x0003;
    /// The device name.
    pub const device_name: u16 = 0x0005;
    /// The keyboard LED state.
    pub const led_state: u16 = 0x0008;
    /// The battery level.
    pub const battery: u16 = 0x1000;
    /// The receiver information: the devices that are paired with it.
    pub const receiver_info: u16 = 0x1B04;
};

/// The functions of a feature.
pub const Function = struct {
    /// Get: the host asks, the device answers.
    pub const get: u8 = 0x00;
    /// Set: the host tells.
    pub const set: u8 = 0x01;
};

/// The parameters of the root feature.
pub const RootFunction = struct {
    /// Ask for the feature index of a feature ID.
    pub const get_feature_index: u8 = 0x00;
    /// Ask for the type and the version of a feature.
    pub const get_feature_info: u8 = 0x01;
};

/// The parameters of the device name feature.
pub const NameFunction = struct {
    /// Ask for the name of the device.
    pub const get_name: u8 = 0x00;
    /// The name types.
    pub const name_type_full: u8 = 0x01;
    pub const name_type_short: u8 = 0x02;
};

/// The parameters of the battery feature.
pub const BatteryFunction = struct {
    /// Ask for the battery level.
    pub const get_battery_level: u8 = 0x00;
    /// Ask for what the battery can report.
    pub const get_battery_capability: u8 = 0x10;
};

/// The parameters of the LED feature.
pub const LedFunction = struct {
    /// Set the LED state.
    pub const set_led_state: u8 = 0x01;
};

/// The LED bits, from the HID++ specification.
pub const Led = struct {
    pub const num_lock: u8 = 0x01;
    pub const caps_lock: u8 = 0x02;
    pub const scroll_lock: u8 = 0x04;
    pub const compose: u8 = 0x08;
};

/// A parsed report.
pub const Report = struct {
    /// The report ID: 0x10 or 0x11.
    report_id: u8 = 0,
    /// The index of the device the report is about.
    device_index: u8 = 0,
    /// The feature the report belongs to.
    feature_index: u8 = 0,
    /// The function.
    function: u8 = 0,
    /// The parameter index: which part of the answer this is.
    parameter_index: u8 = 0,
    /// The parameters.
    params: [LONG_LENGTH]u8 = @splat(0),
    /// The number of valid parameter bytes.
    param_len: usize = 0,

    /// Parse a report.
    ///
    /// Returns null when the bytes are not a HID++ report at all.
    pub fn parse(data: []const u8) ?Report {
        if (data.len < 2) return null;

        var self = Report{};
        self.report_id = data[0];
        self.device_index = data[1];

        switch (self.report_id) {
            REPORT_ID_SHORT => {
                if (data.len < SHORT_LENGTH) return null;
                self.feature_index = data[2];
                self.function = data[3] >> 4;
                self.parameter_index = data[3] & 0x0F;
                self.param_len = SHORT_LENGTH - 5;
                @memcpy(self.params[0..self.param_len], data[5..5 + self.param_len]);
            },
            REPORT_ID_LONG => {
                if (data.len < LONG_LENGTH) return null;
                self.feature_index = data[2];
                self.function = data[3] >> 4;
                self.parameter_index = data[3] & 0x0F;
                self.param_len = LONG_LENGTH - 10;
                @memcpy(self.params[0..self.param_len], data[10..10 + self.param_len]);
            },
            else => return null,
        }

        return self;
    }

    /// The feature the report is about, when the feature index is known.
    pub fn featureId(self: Report, table: *const FeatureTable) ?u16 {
        return table.featureOfIndex(self.feature_index);
    }
};

/// The mapping from a feature index to a feature ID.
///
/// A device does not tell the host which features it has; the host asks
/// the root feature for the index of every feature it cares about.
pub const FeatureTable = struct {
    /// The feature ID and the index it was given.
    entries: [16]Entry = @splat(.{ .id = 0, .index = 0xFF }),

    pub const Entry = struct {
        id: u16 = 0,
        index: u8 = 0xFF,
    };

    /// Record the index of a feature.
    pub fn set(self: *FeatureTable, id: u16, index: u8) void {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 1) {
            if (self.entries[i].id == id) {
                self.entries[i].index = index;
                return;
            }
            if (self.entries[i].index == 0xFF) {
                self.entries[i].id = id;
                self.entries[i].index = index;
                return;
            }
        }
    }

    /// The index of a feature, if it is known.
    pub fn indexOf(self: *const FeatureTable, id: u16) ?u8 {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 1) {
            if (self.entries[i].index == 0xFF) continue;
            if (self.entries[i].id == id) return self.entries[i].index;
        }
        return null;
    }

    /// The feature ID of an index, if it is known.
    pub fn featureOfIndex(self: *const FeatureTable, index: u8) ?u16 {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 1) {
            if (self.entries[i].index == 0xFF) continue;
            if (self.entries[i].index == index) return self.entries[i].id;
        }
        return null;
    }
};

/// Build a short report.
///
/// This is the "ask the root feature for the index of a feature" request
/// that every HID++ conversation starts with.
pub fn buildShortRequest(
    buf: []u8,
    device_index: u8,
    feature_index: u8,
    function: u8,
    parameter_index: u8,
    params: []const u8,
) ?usize {
    if (buf.len < SHORT_LENGTH) return null;
    if (params.len > SHORT_LENGTH - 5) return null;

    buf[0] = REPORT_ID_SHORT;
    buf[1] = device_index;
    buf[2] = feature_index;
    buf[3] = (function << 4) | (parameter_index & 0x0F);
    buf[4] = 0; // the software ID
    @memcpy(buf[5 .. 5 + params.len], params);
    return SHORT_LENGTH;
}

/// Build a long report.
pub fn buildLongRequest(
    buf: []u8,
    device_index: u8,
    feature_index: u8,
    function: u8,
    parameter_index: u8,
    software_id: u16,
    params: []const u8,
) ?usize {
    if (buf.len < LONG_LENGTH) return null;
    if (params.len > LONG_LENGTH - 10) return null;

    buf[0] = REPORT_ID_LONG;
    buf[1] = device_index;
    buf[2] = feature_index;
    buf[3] = (function << 4) | (parameter_index & 0x0F);
    buf[4] = @truncate(software_id);
    buf[5] = @truncate(software_id >> 8);
    // The device address; the receiver fills it in for the short form and
    // the host uses it for the long one.
    @memset(buf[6..10], 0);
    @memcpy(buf[10 .. 10 + params.len], params);
    return LONG_LENGTH;
}

/// The request that asks the root feature for the index of a feature.
///
/// Linux does this in `hidpp_get_feature_index()`.
pub fn featureIndexRequest(buf: []u8, device_index: u8, feature_id: u16) ?usize {
    const params = [_]u8{ @truncate(feature_id & 0xFF), @truncate(feature_id >> 8) };
    return buildShortRequest(buf, device_index, 0x00, RootFunction.get_feature_index, 0x00, &params);
}

/// The request that asks for the name of a device.
pub fn nameRequest(buf: []u8, device_index: u8, feature_index: u8, name_type: u8) ?usize {
    const params = [_]u8{name_type};
    return buildShortRequest(buf, device_index, feature_index, NameFunction.get_name, 0x00, &params);
}

/// The request that asks for the battery level.
pub fn batteryRequest(buf: []u8, device_index: u8, feature_index: u8) ?usize {
    return buildShortRequest(buf, device_index, feature_index, BatteryFunction.get_battery_level, 0x00, &[_]u8{});
}

/// The request that sets the LED state of a keyboard.
pub fn ledRequest(buf: []u8, device_index: u8, feature_index: u8, leds: u8) ?usize {
    const params = [_]u8{ leds };
    return buildShortRequest(buf, device_index, feature_index, LedFunction.set_led_state, 0x00, &params);
}

/// The battery level of a device, in percent.
pub fn batteryLevel(report: Report) ?u8 {
    if (report.function != BatteryFunction.get_battery_level) return null;
    if (report.param_len < 1) return null;
    return report.params[0];
}

/// The name of a device, as far as the reports have delivered it.
///
/// The name comes in parts: every report carries a few bytes and the
/// parameter index says which part.
pub fn appendName(name: []u8, used: *usize, report: Report) void {
    if (report.function != NameFunction.get_name) return;
    const part = report.parameter_index;
    if (part * 4 >= name.len) return;

    var i: usize = 0;
    while (i < report.param_len and i < 4) : (i += 1) {
        const at = part * 4 + i;
        if (at >= name.len) break;
        name[at] = report.params[i];
        if (used.* < at + 1) used.* = at + 1;
    }
}
