/// A virtual display: the host-side view of one guest's video memory.
///
/// In the final design this is a window into *guest* RAM - the guest's video
/// driver writes to it through the hypervisor's custom GPU device, and the
/// compositor reads the same bytes.  Today the buffer is host memory
/// allocated from the PMM, but it is allocated as whole pages and exposed as
/// a physical address precisely so that it can be mapped into a guest's
/// address space later without changing anything above this file.
///
/// Pixels are 0x00RRGGBB, the same layout the framebuffer shadow uses, so
/// compositing a virtual display into the physical framebuffer is a straight
/// copy (or a nearest-neighbour rescale).
const std = @import("std");
const root = @import("root");
const pmm = root.pmm;

/// A rectangle, in pixels.
pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn isEmpty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }
};

/// The largest virtual display we support.  A 1920x1080 guest is 8 MB.
pub const MAX_OUTPUT_WIDTH: u32 = 1920;
pub const MAX_OUTPUT_HEIGHT: u32 = 1080;
pub const MAX_OUTPUTS: usize = 8;

pub const Output = struct {
    /// Host pointer to the pixel buffer.  0x00RRGGBB per pixel.
    pixels: [*]u32 = undefined,
    /// Physical address of the buffer, so a guest can be given a mapping.
    phys_base: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Row stride in pixels.  Equal to `width`; kept separate so a guest
    /// display with a padded stride can be modelled without changing the
    /// compositor.
    stride_px: u32 = 0,
    capacity_px: usize = 0,
    /// The region that changed since the last composite.
    dirty: Rect = .{},
    /// Short name shown in the status strip.
    name: [16]u8 = [_]u8{0} ** 16,
    /// The guest profile this display was created for.
    profile: []const u8 = "generic",
    /// Set when the guest has something to show.
    live: bool = false,

    pub fn init(width: u32, height: u32, name: []const u8, profile: []const u8) !Output {
        if (width == 0 or height == 0) return error.InvalidSize;
        if (width > MAX_OUTPUT_WIDTH or height > MAX_OUTPUT_HEIGHT) return error.SizeTooLarge;

        const total = @as(usize, width) * height;
        const bytes = (total * 4 + 4095) & ~@as(usize, 4095);
        const pages = bytes / 4096;
        const phys = pmm.allocPages(pages) orelse return error.OutOfMemory;

        var self: Output = .{
            .pixels = @ptrFromInt(phys),
            .phys_base = phys,
            .width = width,
            .height = height,
            .stride_px = width,
            .capacity_px = total,
            .profile = profile,
        };
        @memset(self.pixels[0..total], 0);
        self.setName(name);
        return self;
    }

    pub fn deinit(self: *Output) void {
        if (self.capacity_px == 0) return;
        const bytes = (self.capacity_px * 4 + 4095) / 4096;
        pmm.freePages(@intFromPtr(self.pixels), bytes);
        self.pixels = undefined;
        self.capacity_px = 0;
        self.phys_base = 0;
        self.live = false;
    }

    pub fn setName(self: *Output, name: []const u8) void {
        @memset(&self.name, 0);
        const n = @min(name.len, self.name.len);
        @memcpy(self.name[0..n], name[0..n]);
    }

    pub fn nameSlice(self: *const Output) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..n];
    }

    /// Erase the whole display.
    pub fn clear(self: *Output, rgb: u32) void {
        if (self.capacity_px == 0) return;
        @memset(self.pixels[0..self.capacity_px], rgb);
        self.dirty = .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
    }

    /// Mark the whole display as changed.
    pub fn touchAll(self: *Output) void {
        self.dirty = .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
    }

    /// Mark a rectangle as changed.  The rectangle is clipped to the display.
    pub fn markDirty(self: *Output, x: u32, y: u32, w: u32, h: u32) void {
        if (w == 0 or h == 0) return;
        const x1 = @min(x +| w, self.width);
        const y1 = @min(y +| h, self.height);
        if (x >= x1 or y >= y1) return;
        if (self.dirty.isEmpty()) {
            self.dirty = .{ .x = x, .y = y, .w = x1 - x, .h = y1 - y };
            return;
        }
        const dx0 = @min(self.dirty.x, x);
        const dy0 = @min(self.dirty.y, y);
        const dx1 = @max(self.dirty.x + self.dirty.w, x1);
        const dy1 = @max(self.dirty.y + self.dirty.h, y1);
        self.dirty = .{ .x = dx0, .y = dy0, .w = dx1 - dx0, .h = dy1 - dy0 };
    }

    /// Write one pixel.  Out-of-range writes are dropped.
    pub fn putPixel(self: *Output, x: u32, y: u32, rgb: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * self.stride_px + x] = rgb;
        self.markDirty(x, y, 1, 1);
    }

    pub fn getPixel(self: *const Output, x: u32, y: u32) u32 {
        if (x >= self.width or y >= self.height) return 0;
        return self.pixels[@as(usize, y) * self.stride_px + x];
    }

    /// Fill a rectangle.
    pub fn fillRect(self: *Output, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
        if (w == 0 or h == 0) return;
        const x1 = @min(x +| w, self.width);
        const y1 = @min(y +| h, self.height);
        if (x >= x1 or y >= y1) return;
        var yy = y;
        while (yy < y1) : (yy += 1) {
            const row = self.pixels + @as(usize, yy) * self.stride_px;
            var xx = x;
            while (xx < x1) : (xx += 1) {
                row[xx] = rgb;
            }
        }
        self.markDirty(x, y, x1 - x, y1 - y);
    }

    /// Draw a horizontal line.
    pub fn hLine(self: *Output, x: u32, y: u32, len: u32, rgb: u32) void {
        self.fillRect(x, y, len, 1, rgb);
    }

    /// Draw a vertical line.
    pub fn vLine(self: *Output, x: u32, y: u32, len: u32, rgb: u32) void {
        self.fillRect(x, y, 1, len, rgb);
    }

    /// Draw a rectangle outline.
    pub fn rect(self: *Output, x: u32, y: u32, w: u32, h: u32, thickness: u32, rgb: u32) void {
        if (thickness == 0 or w == 0 or h == 0) return;
        self.fillRect(x, y, w, thickness, rgb);
        self.fillRect(x, y + h -| thickness, w, thickness, rgb);
        self.fillRect(x, y, thickness, h, rgb);
        self.fillRect(x + w -| thickness, y, thickness, h, rgb);
    }

    /// Draw a small filled block of pixels - the building block of the
    /// bitmap font used by the guest console renderer.
    pub fn setPixelRaw(self: *Output, x: u32, y: u32, rgb: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * self.stride_px + x] = rgb;
    }

    /// Clear the dirty rectangle, after the compositor has drawn it.
    pub fn clearDirty(self: *Output) void {
        self.dirty = .{};
    }
};
