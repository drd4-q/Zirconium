/// A text-cell rendering target.
///
/// The console engine knows nothing about VGA text memory or a linear frame
/// buffer: it asks the active surface to paint a cell.  Switching between the
/// two is a pointer swap, and adding a third target later (a serial console,
/// a remote framebuffer) means writing one new surface, not a new console.
///
/// Surfaces paint *cells*.  Free-form graphics - rectangles, lines, RGB text -
/// are not part of this interface; they live on the graphics-only extension in
/// `fb.zig`, because the VGA text buffer cannot express them.
pub const Surface = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Size of one character cell, in pixels.
        cell_width: *const fn (ctx: *anyopaque) u32,
        cell_height: *const fn (ctx: *anyopaque) u32,
        /// Grid size, in cells.
        grid_cols: *const fn (ctx: *anyopaque) u32,
        grid_rows: *const fn (ctx: *anyopaque) u32,
        /// Paint one cell.  `fg`/`bg` are palette indices (0..15).
        put_cell: *const fn (ctx: *anyopaque, col: u32, row: u32, ch: u8, fg: u8, bg: u8) void,
        /// Erase the whole grid to `bg`.
        clear: *const fn (ctx: *anyopaque, bg: u8) void,
        /// Push pending drawing out to the hardware.
        flush: *const fn (ctx: *anyopaque) void,
        /// Scroll the text region up by `rows` cell rows.
        ///
        /// `cols` is the width of the region the console is using, which can be
        /// narrower than the surface's own grid (the console clamps its grid to
        /// a maximum).  Scrolling the pixels is much cheaper than repainting
        /// every cell, and it is the only way to keep a 60-row console from
        /// costing a million pixel writes per newline.
        scroll_up: *const fn (ctx: *anyopaque, rows: u32, cols: u32) void,
    };

    pub inline fn cellWidth(self: Surface) u32 {
        return self.vtable.cell_width(self.ctx);
    }

    pub inline fn cellHeight(self: Surface) u32 {
        return self.vtable.cell_height(self.ctx);
    }

    pub inline fn gridCols(self: Surface) u32 {
        return self.vtable.grid_cols(self.ctx);
    }

    pub inline fn gridRows(self: Surface) u32 {
        return self.vtable.grid_rows(self.ctx);
    }

    pub inline fn putCell(self: Surface, col: u32, row: u32, ch: u8, fg: u8, bg: u8) void {
        self.vtable.put_cell(self.ctx, col, row, ch, fg, bg);
    }

    pub inline fn clear(self: Surface, bg: u8) void {
        self.vtable.clear(self.ctx, bg);
    }

    pub inline fn flush(self: Surface) void {
        self.vtable.flush(self.ctx);
    }

    pub inline fn scrollUp(self: Surface, rows: u32, cols: u32) void {
        self.vtable.scroll_up(self.ctx, rows, cols);
    }
};
