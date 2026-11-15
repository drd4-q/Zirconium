//! The DRM CRTC and the fbdev emulation on top of it.
//!
//! Ported from the Linux kernel's:
//!
//!   * `drivers/gpu/drm/drm_crtc.c` - the CRTC: the mode it runs at, the
//!     power state and the framebuffer it scans out.
//!   * `drivers/gpu/drm/drm_fbdev_client.c` - the fbdev emulation: the
//!     `fb_var_screeninfo` and `fb_fix_screeninfo` the userspace sees and
//!     the `set_var` / `set_fix` calls it can make.
//!
//! The CRTC is the piece that drives a connector: it holds the mode, it
//! takes the framebuffer and it is switched on and off.  The fbdev layer
//! is the compatibility interface that lets a program that only knows
//! about `/dev/fb0` talk to a DRM device.

const connector_mod = @import("connector.zig");

pub const Mode = connector_mod.Mode;
pub const Connector = connector_mod.Connector;
pub const Dpms = connector_mod.Dpms;

/// The CRTC.
pub const Crtc = struct {
    /// The connector the CRTC drives.
    connector: *Connector = undefined,
    /// The mode the CRTC runs at.
    mode: ?Mode = null,
    /// True when the CRTC is enabled.
    enabled: bool = false,
    /// The power state.
    dpms: Dpms = .on,
    /// The number of frames the CRTC has shown.
    frames: u64 = 0,

    /// The hardware state of the CRTC, the way Linux's `drm_crtc` keeps it.
    ///
    /// The framebuffer is the shadow the display is scanned out of; the
    /// CRTC only ever points at it.
    framebuffer: ?*FrameBuffer = null,

    /// Switch the CRTC on.
    pub fn enable(self: *Crtc) void {
        self.enabled = true;
        self.dpms = .on;
    }

    /// Switch the CRTC off.
    pub fn disable(self: *Crtc) void {
        self.enabled = false;
        self.dpms = .off;
    }

    /// Set the mode the CRTC runs at.
    ///
    /// Linux's `drm_crtc_set_mode()`: the mode has to come from the
    /// connector, and the CRTC is disabled while it changes.
    pub fn setMode(self: *Crtc, mode: Mode) bool {
        const was_enabled = self.enabled;
        if (was_enabled) self.disable();

        if (!self.connector.setMode(mode)) {
            if (was_enabled) self.enable();
            return false;
        }

        self.mode = mode;
        if (was_enabled) self.enable();
        return true;
    }

    /// Point the CRTC at a framebuffer.
    pub fn setFramebuffer(self: *Crtc, fb: ?*FrameBuffer) void {
        self.framebuffer = fb;
    }

    /// Show the next frame.
    pub fn flip(self: *Crtc) void {
        if (!self.enabled) return;
        self.frames += 1;
    }
};

/// A framebuffer: the memory the display is scanned out of.
pub const FrameBuffer = struct {
    /// The address of the pixels.
    addr: usize = 0,
    /// The width and the height in pixels.
    width: u32 = 0,
    height: u32 = 0,
    /// The distance between two lines in bytes.
    pitch: u32 = 0,
    /// The number of bits per pixel.
    bpp: u8 = 32,
    /// The format, in the DRM's fourcc form.
    format: u32 = 0,
};

/// The DRM fourcc formats the kernel uses.
pub const Format = struct {
    pub const argb8888: u32 = 0x34325241; // "AR24"
    pub const xrgb8888: u32 = 0x34325258; // "XR24"
    pub const rgb565: u32 = 0x36314752; // "RG16"
};

/// The variable screen information, from Linux's `fb_var_screeninfo`.
///
/// Only the fields the kernel actually uses are here.
pub const VarScreenInfo = struct {
    xres: u32 = 0,
    yres: u32 = 0,
    xres_virtual: u32 = 0,
    yres_virtual: u32 = 0,
    bits_per_pixel: u8 = 0,
    grayscale: u8 = 0,
};

/// The fixed screen information, from Linux's `fb_fix_screeninfo`.
pub const FixScreenInfo = struct {
    id: [16]u8 = @splat(0),
    type: u8 = 0,
    type_aux: u8 = 0,
    visual: u8 = 0,
    xpanstep: u16 = 0,
    ypanstep: u16 = 0,
    ywrapstep: u16 = 0,
    line_length: u32 = 0,
    mm_height: u32 = 0,
    mm_width: u32 = 0,
    accel_flags: u32 = 0,
    capabilities: u16 = 0,
    reserved: [2]u16 = @splat(0),
};

/// The fbdev emulation: the compatibility layer over a CRTC.
///
/// Linux's `drm_fbdev_generic_setup()` registers one of these per display,
/// and a program that only knows about `/dev/fb0` talks to it.
pub const FbDev = struct {
    /// The CRTC the fbdev drives.
    crtc: *Crtc = undefined,
    /// The variable screen information.
    var_info: VarScreenInfo = .{},
    /// The fixed screen information.
    fix_info: FixScreenInfo = .{},

    /// Set the framebuffer up, the way Linux's
    /// `drm_fbdev_generic_setup()` does: the mode comes from the CRTC and
    /// the fix information describes the memory.
    pub fn setup(self: *FbDev, crtc: *Crtc, fb: *FrameBuffer) void {
        self.crtc = crtc;

        self.var_info.xres = fb.width;
        self.var_info.yres = fb.height;
        self.var_info.xres_virtual = fb.width;
        self.var_info.yres_virtual = fb.height;
        self.var_info.bits_per_pixel = fb.bpp;

        @memset(&self.fix_info.id, 0);
        @memcpy(self.fix_info.id[0..6], "ZIRCFB");
        self.fix_info.type = 0; // FB_TYPE_PACKED_PIXELS
        self.fix_info.visual = 2; // FB_VISUAL_TRUECOLOR
        self.fix_info.line_length = fb.pitch;
        self.fix_info.capabilities = 0;

        crtc.setFramebuffer(fb);
    }

    /// The `FBIOGET_VSCREENINFO` / `FBIOGET_FSCREENINFO` handlers: the
    /// userspace asks for the information and gets it.
    pub fn getVar(self: *const FbDev) VarScreenInfo {
        return self.var_info;
    }

    pub fn getFix(self: *const FbDev) FixScreenInfo {
        return self.fix_info;
    }

    /// The `FBIOPUT_VSCREENINFO` handler.
    ///
    /// Linux's `drm_fbdev_ioctl()` only accepts a change that keeps the
    /// resolution: the mode is the CRTC's business, not the fbdev's.
    pub fn setVar(self: *FbDev, new_var: VarScreenInfo) bool {
        if (new_var.xres != self.var_info.xres or new_var.yres != self.var_info.yres) return false;
        self.var_info = new_var;
        return true;
    }
};
