//! The DRM connector model.
//!
//! Ported from the Linux kernel's `drivers/gpu/drm/drm_connector.c` and
//! `include/drm/drm_connector.h`: the status of a connector, the way it is
//! detected, and the mode list it offers.
//!
//! A connector is the kernel's name for "a socket a display can be
//! plugged into".  The status says whether something is plugged in, and
//! the mode list says what it can do.

const edid_mod = @import("edid.zig");

pub const Edid = edid_mod.Edid;
pub const Mode = edid_mod.Mode;

/// The status of a connector, from Linux's `drm_connector_status`.
pub const Status = enum {
    /// The connector is definitely connected to a sink device and can be
    /// enabled.
    connected,
    /// The connector is not connected to a sink device that can be probed.
    disconnected,
    /// The status could not be determined reliably.  The connector can
    /// still be lit up with one of the fallback modes.
    unknown,
};

/// The power state of a display, from Linux's `drm_connector` DPMS.
pub const Dpms = enum {
    on,
    standby,
    /// The display is suspended.  The name avoids `suspend`, which is a
    /// keyword.
    suspended,
    off,
};

/// The maximum number of modes a connector offers.
pub const MAX_MODES: usize = 24;

/// A connector.
pub const Connector = struct {
    /// The name of the connector, the way the DRM code names it.
    name: []const u8 = "unknown",
    /// The status of the connector.
    status: Status = .unknown,
    /// The power state.
    dpms: Dpms = .on,
    /// True when the connector is enabled (its CRTC is driving it).
    enabled: bool = false,
    /// The EDID the connector read, if it read one.
    edid: ?Edid = null,
    /// The modes the connector offers.
    modes: [MAX_MODES]Mode = @splat(.{}),
    mode_count: usize = 0,
    /// The mode the connector is set to.
    current: ?Mode = null,

    /// Set the status.
    ///
    /// Linux's `drm_connector_set_status()` refuses to go from connected to
    /// disconnected and back without a detect, because the status is what
    /// the userspace uses to decide whether to light the connector up.
    pub fn setStatus(self: *Connector, status: Status) void {
        self.status = status;
    }

    /// Detect whether a display is plugged in.
    ///
    /// Linux's `drm_connector_helper_detect()` asks the hardware; here the
    /// EDID is the evidence: a display that identifies itself is connected.
    /// A connector without an EDID stays unknown, because "no EDID" is not
    /// the same as "no display".
    pub fn detect(self: *Connector) Status {
        if (self.edid != null) {
            self.status = .connected;
        } else if (self.status == .connected) {
            self.status = .unknown;
        }
        return self.status;
    }

    /// Take the EDID of the display and build the mode list from it.
    ///
    /// This is Linux's `drm_edid_connector_update()`: the EDID is the
    /// source of the modes, and the preferred mode is the largest one.
    pub fn setEdid(self: *Connector, edid: ?Edid) void {
        self.edid = edid;
        self.mode_count = 0;

        if (edid) |e| {
            var i: usize = 0;
            while (i < e.mode_count and self.mode_count < MAX_MODES) : (i += 1) {
                self.modes[self.mode_count] = e.modes[i];
                self.mode_count += 1;
            }
            // The established timings come on top of the detailed ones.
            var established: [16]Mode = @splat(.{});
            const count = e.establishedModes(&established);
            var k: usize = 0;
            while (k < count and self.mode_count < MAX_MODES) : (k += 1) {
                self.modes[self.mode_count] = established[k];
                self.mode_count += 1;
            }
        }

        _ = self.detect();
    }

    /// The preferred mode of the connector, if it has one.
    pub fn preferredMode(self: *const Connector) ?Mode {
        if (self.edid) |e| return e.preferredMode();
        return null;
    }

    /// Set the mode the connector runs at.
    ///
    /// Linux's `drm_crtc_set_mode()`: the mode has to be one the connector
    /// offers, and the old mode is put back first.
    pub fn setMode(self: *Connector, new_mode: Mode) bool {
        var i: usize = 0;
        while (i < self.mode_count) : (i += 1) {
            if (self.modes[i].h_active == new_mode.h_active and
                self.modes[i].v_active == new_mode.v_active and
                self.modes[i].clock_khz == new_mode.clock_khz)
            {
                self.current = self.modes[i];
                return true;
            }
        }
        return false;
    }

    /// The number of modes the connector offers.
    pub fn modeCount(self: *const Connector) usize {
        return self.mode_count;
    }

    /// The mode at `index`.
    pub fn mode(self: *const Connector, index: usize) ?Mode {
        if (index >= self.mode_count) return null;
        return self.modes[index];
    }
};
