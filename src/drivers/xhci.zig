//! xHCI (USB 3.0) host controller driver with HID boot-protocol support.
//!
//! Brings up QEMU's `qemu-xhci` controller over MMIO, enumerates attached
//! devices (usb-kbd / usb-tablet) through the standard EnableSlot →
//! AddressDevice → ConfigureEndpoint sequence, then polls their interrupt
//! endpoints for HID reports:
//!   * usb-kbd    → 8-byte boot-keyboard reports decoded into the PS/2-style
//!                  scancode ring used by drivers/keyboard.zig
//!   * usb-tablet → absolute-pointer reports mapped onto drivers/mouse.zig
//!
//! Everything runs without interrupts: a single pollHid() call drains the
//! event ring and re-arms pending transfers; the scheduler ticks it at 100 Hz.

const std = @import("std");
const serial = @import("../system/serial.zig");
const pci = @import("pci.zig");

// ---------------------------------------------------------------------------
// Register layout
// ---------------------------------------------------------------------------

const CapRegs = struct {
    base: usize, // MMIO base of capability space

    fn capLength(self: CapRegs) u8 {
        return @as(*volatile u8, @ptrFromInt(self.base)).*;
    }
    /// MaxPorts[31:24] MaxIntrs[23:16] MaxSlots[7:0]
    fn hcspParams1(self: CapRegs) u32 {
        return @as(*volatile u32, @ptrFromInt(self.base + 0x04)).*;
    }
    fn hccParams1(self: CapRegs) u32 {
        return @as(*volatile u32, @ptrFromInt(self.base + 0x10)).*;
    }
    fn opBase(self: CapRegs) usize {
        return self.base + self.capLength();
    }
};

const OpRegs = struct {
    base: usize,

    fn uscmd(self: OpRegs) u32 {
        return @as(*volatile u32, @ptrFromInt(self.base)).*;
    }
    fn setUsbcmd(self: OpRegs, v: u32) void {
        @as(*volatile u32, @ptrFromInt(self.base)).* = v;
    }
    fn usbsts(self: OpRegs) u32 {
        return @as(*volatile u32, @ptrFromInt(self.base + 0x04)).*;
    }
    fn crcr(self: OpRegs) u64 {
        const lo = @as(*volatile u32, @ptrFromInt(self.base + 0x18)).*;
        return lo;
    }
    fn setCrcr(self: OpRegs, v: u64) void {
        // CRCR is 64-bit but only the low word is writable field-wise here;
        // QEMU honours a single 32-bit write for our small rings.
        @as(*volatile u32, @ptrFromInt(self.base + 0x18)).* = @intCast(v & 0xFFFFFFFF);
    }
    fn setDcbaap(self: OpRegs, v: u64) void {
        @as(*volatile u32, @ptrFromInt(self.base + 0x30)).* = @intCast(v & 0xFFFFFFFF);
        @as(*volatile u32, @ptrFromInt(self.base + 0x34)).* = @intCast(v >> 32);
    }
    fn setConfig(self: OpRegs, v: u32) void {
        @as(*volatile u32, @ptrFromInt(self.base + 0x38)).* = v;
    }
    /// Port status/control: OPERATIONAL + 0x400, 4 bytes per port (1-based).
    fn portsc(self: OpRegs, port1: u8) *volatile u32 {
        return @ptrFromInt(self.base + 0x400 + @as(usize, port1 - 1) * 4);
    }
};

// USBCMD bits
const CMD_RUN: u32 = 1 << 0;
const CMD_HCRST: u32 = 1 << 1;
const CMD_INTE: u32 = 1 << 2;
// USBSTS bits
const STS_HCH: u32 = 1 << 0;
const STS_CNR: u32 = 1 << 11;
// PORTSC bits
const PORT_CCS: u32 = 1 << 0;
const PORT_PED: u32 = 1 << 1;
const PORT_OCA: u32 = 1 << 3;
const PORT_RESET: u32 = 1 << 4;
const PORT_PLS_MASK: u32 = 0xF << 5;
const PORT_PP: u32 = 1 << 9;
const PORT_CSC: u32 = 1 << 17;
const PORT_PEC: u32 = 1 << 18;
const PORT_WRC: u32 = 1 << 19;
const PORT_PRSC: u32 = 1 << 20;
const PORT_SPEED_MASK: u32 = 0xF << 10;

// TRB types
const TRB_NORMAL: u32 = 1;
const TRB_SETUP_STAGE: u32 = 2;
const TRB_DATA_STAGE: u32 = 3;
const TRB_STATUS_STAGE: u32 = 4;
const TRB_LINK: u32 = 6;
const TRB_ENABLE_SLOT: u32 = 9;
const TRB_ADDRESS_DEVICE: u32 = 11;
const TRB_CONFIGURE_ENDPOINT: u32 = 12;
const TRB_NOOP: u32 = 23;

const TRB_IOC: u32 = 1 << 5;
const TRB_IDT: u32 = 1 << 6;
const TRB_CYCLE: u32 = 1 << 0;
const TRB_TYPE_SHIFT: u32 = 10;

// Event TRB types
const EV_TRANSFER: u32 = 32;
const EV_COMMAND_COMPLETION: u32 = 33;
const EV_PORT_STATUS: u32 = 34;

// Completion codes we care about
const CC_SUCCESS: u32 = 1;

const TRB_SIZE: usize = 16;
const RING_COUNT: usize = 64; // TRBs per ring (power of two)

/// One TRB, field-accessible.
const Trb = extern struct {
    param: u64 = 0,
    status: u32 = 0, // [16:22] length, [9] IOC handled via flags below
    control: u32 = 0,

    fn setType(self: *Trb, t: u32) void {
        self.control = (self.control & ~(@as(u32, 0x3F) << TRB_TYPE_SHIFT)) | (t << TRB_TYPE_SHIFT);
    }
    fn trbType(self: *const Trb) u32 {
        return (self.control >> TRB_TYPE_SHIFT) & 0x3F;
    }
    fn setLen(self: *Trb, l: u32) void {
        self.status = (self.status & ~@as(u32, 0x1FFFF << 16)) | ((l & 0x1FFFF) << 16);
    }
};

// ---------------------------------------------------------------------------
// Driver state (single controller — enough for QEMU and typical hardware)
// ---------------------------------------------------------------------------

var detected: bool = false;
var ready: bool = false;
var cap: CapRegs = undefined;
var op: OpRegs = undefined;
var max_ports: u8 = 0;
var max_slots: u8 = 0;
var rt_base: usize = 0;

var dcbaa_page: [4096]u8 align(4096) = undefined; // DCBAA (512 slots * 8B)
var ctx_page: [4096]u8 align(4096) = undefined; // input + device contexts
var cmd_ring_buf: [4096]u8 align(4096) = undefined; // 256 TRBs space
var evt_seg_buf: [4096]u8 align(4096) = undefined; // 256 event TRBs
var erst_buf: [64]u8 align(64) = undefined;

const cmd_ring: *[RING_COUNT]Trb = @ptrCast(@alignCast(&cmd_ring_buf));
const evt_ring: *[RING_COUNT]Trb = @ptrCast(@alignCast(&evt_seg_buf));

var cmd_enqueue: usize = 0;
var cmd_cycle: u1 = 1;
var evt_dequeue: usize = 0;
var evt_cycle: u1 = 1;

pub const HidDevKind = enum { none, keyboard, tablet };
const DevInfo = struct {
    slot: u8 = 0,
    kind: HidDevKind = .none,
    ep_addr: u8 = 0,
    ep_mps: u16 = 0,
    interval: u32 = 0,
    ring_phys: u64 = 0,
    enqueue: usize = 0,
    cycle: u1 = 1,
    vendor: u16 = 0,
    product: u16 = 0,
};
var devices: [4]DevInfo = [_]DevInfo{.{}} ** 4;
var dev_count: usize = 0;

// Scratch transfer buffer shared by posted interrupt-IN requests (one TRB per
// device points here; the newest report simply overwrites the previous one).
var kbd_report: [8]u8 align(16) = .{0} ** 8;
var tab_report: [8]u8 align(16) = .{0} ** 8;

pub fn isReady() bool {
    return ready;
}

pub fn deviceCount() usize {
    var n: usize = 0;
    for (devices) |d| {
        if (d.kind != .none) n += 1;
    }
    return n;
}

pub fn deviceSummary(buf: []u8) []const u8 {
    var ln: usize = 0;
    for (devices) |d| {
        if (d.kind == .none) continue;
        const tag: []const u8 = switch (d.kind) {
            .keyboard => "HID keyboard",
            .tablet => "HID tablet (absolute mouse)",
            .none => unreachable,
        };
        if (ln > 0) {
            @memcpy(buf[ln..][0..2], ", ");
            ln += 2;
        }
        @memcpy(buf[ln..][0..tag.len], tag);
        ln += tag.len;
    }
    if (ln == 0) {
        const none = "no HID devices";
        @memcpy(buf[0..none.len], none);
        ln = none.len;
    }
    return buf[0..ln];
}

// ---------------------------------------------------------------------------
// Low-level helpers
// ---------------------------------------------------------------------------

fn rd32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
fn wr32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

fn spinMs(count: usize) void {
    var i: usize = 0;
    while (i < count * 20000) : (i += 1) {
        asm volatile ("pause");
    }
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

pub fn init(dev: *const pci.PciDevice) bool {
    detected = false;
    ready = false;

    // Enable MMIO + bus master so the controller can DMA.
    pci.enableBusMaster(dev.bus, dev.dev, dev.func);

    cap = .{ .base = dev.bar0 & ~@as(u32, 0xF) };
    if (cap.base == 0) {
        serial.serialWrite("[XHCI] Controller has no MMIO BAR\n");
        return false;
    }

    max_ports = @truncate((cap.hcspParams1() >> 24) & 0xFF);
    max_slots = @truncate(cap.hcspParams1() & 0xFF);
    if (max_ports == 0 or max_slots == 0) {
        serial.serialWrite("[XHCI] Bogus HCSPARAMS\n");
        return false;
    }

    op = .{ .base = cap.opBase() };

    serial.serialWrite("[XHCI] Controller at PCI ");
    serial.serialWriteDec(dev.bus);
    serial.serialWrite(":");
    serial.serialWriteDec(dev.dev);
    serial.serialWrite(", MMIO 0x");
    serial.serialWriteHex(@truncate(cap.base));
    serial.serialWrite(", ports=");
    serial.serialWriteDec(max_ports);
    serial.serialWrite(" slots=");
    serial.serialWriteDec(max_slots);
    serial.serialWrite("\n");

    // Stop controller if running, then reset it.
    var c = op.uscmd();
    c &= ~CMD_RUN;
    c &= ~CMD_INTE;
    op.setUsbcmd(c);
    var spins: usize = 2_000_000;
    while ((op.usbsts() & STS_HCH) == 0 and spins > 0) : (spins -= 1) {}
    if (spins == 0) {
        serial.serialWrite("[XHCI] Controller refuses to stop\n");
        return false;
    }

    c = op.uscmd();
    op.setUsbcmd(c | CMD_HCRST);
    spins = 2_000_000;
    while ((op.usbsts() & STS_CNR) != 0 and spins > 0) : (spins -= 1) {}
    spinMs(5);

    // Zero our tables.
    @memset(&dcbaa_page, 0);
    @memset(&ctx_page, 0);
    @memset(&cmd_ring_buf, 0);
    @memset(&evt_seg_buf, 0);

    // DCBAA: slot N context pointer at index N.
    const ctx_phys = @intFromPtr(&ctx_page);
    const dcbaa: [*]u64 = @ptrCast(&dcbaa_page);
    var s: usize = 1;
    while (s <= max_slots) : (s += 1) {
        dcbaa[s] = ctx_phys + s * 64; // 32-byte contexts, one per slot line
    }
    op.setDcbaap(@intFromPtr(&dcbaa_page));

    // Command ring: LINK TRB at the end wraps back to entry 0.
    @memset(cmd_ring, std.mem.zeroes(Trb));
    cmd_ring[RING_COUNT - 1] = .{
        .param = @intFromPtr(&cmd_ring),
        .control = (TRB_LINK << TRB_TYPE_SHIFT) | TRB_CYCLE,
    };

    // Program CRCR with the ring base + cycle bit.
    op.setCrcr(@intFromPtr(&cmd_ring) | @as(u64, cmd_cycle));

    // Event ring: single segment. Runtime space is addressed through RTSOFF
    // (capability reg at +0x18); interrupter 0 registers sit at RT+0x20..:
    //   IMAN +0, IMOD +4, ERSTSZ +8, ERSTBA +16, ERDP +24
    const rtsoff = rd32(cap.base + 0x18) & ~@as(u32, 3);
    rt_base = cap.base + rtsoff;
    serial.serialWrite("[XHCI] runtime base 0x");
    serial.serialWriteHex(@as(u32, @truncate(rt_base)));
    serial.serialWrite("\n");

    const erst: *[4]u64 = @ptrCast(&erst_buf);
    erst[0] = @intFromPtr(&evt_ring);
    erst[1] = RING_COUNT;
    wr32(rt_base + 0x28, 1); // ERSTSZ(0)
    {
        const ba: u64 = @intFromPtr(&erst_buf);
        wr32(rt_base + 0x30, @as(u32, @truncate(ba & 0xFFFFFFFF)));
        wr32(rt_base + 0x34, @truncate(ba >> 32));
        const erdp_val: u64 = @intFromPtr(&evt_ring);
        wr32(rt_base + 0x38, @as(u32, @truncate(erdp_val & 0xFFFFFFFF)));
        wr32(rt_base + 0x3C, @truncate(erdp_val >> 32));
    }

    // Power every port BEFORE running the controller.
    var pp: u8 = 1;
    while (pp <= max_ports) : (pp += 1) {
        const ps = op.portsc(pp);
        ps.* |= PORT_PP;
    }
    spinMs(20);

    // Enable slots, run the show.
    op.setConfig(max_slots & 0xFF);
    op.setUsbcmd((op.uscmd() & ~(CMD_HCRST | CMD_INTE)) | CMD_RUN);
    spinMs(50);




    detected = true;

    spinMs(50);
    enumerate();

    ready = true;
    return true;
}

// ---------------------------------------------------------------------------
// Ring helpers
// ---------------------------------------------------------------------------

fn pushCommand(t: Trb) void {
    var t2 = t;
    t2.control |= @as(u32, cmd_cycle);
    cmd_ring[cmd_enqueue] = t2;
    cmd_enqueue = (cmd_enqueue + 1) % (RING_COUNT - 1);
    doorbell(0);
}

/// Doorbell array lives at CAP_BASE + DBOFF (register at cap+0x14, bytes).
fn doorbell(target: u8) void {
    const dboff = rd32(cap.base + 0x14) & ~@as(u32, 3);
    wr32(cap.base + dboff + @as(usize, target) * 4, 0); // DB Target=0 (ring 0)
}

const CmdResult = struct { cc: u32, slot: u8 };

fn waitForCommandCompletion(timeout_ms: usize) ?CmdResult {
    var waited: usize = 0;
    while (waited < timeout_ms * 100) : (waited += 1) {
        if (drainEvents()) |res| return res;
        spinMs(1);
    }
    serial.serialWrite("[XHCI] command timeout\n");
    return null;
}

/// Drain the event ring; returns the FIRST command-completion result found.
fn drainEvents() ?CmdResult {
    var result: ?CmdResult = null;
    var guard: usize = 0;
    while (guard < RING_COUNT) : (guard += 1) {
        const e = &evt_ring[evt_dequeue];
        if ((e.control & TRB_CYCLE) != evt_cycle) break; // empty

        const etype = e.trbType();
        const cc = (e.status >> 24) & 0xFF;

        switch (etype) {
            EV_COMMAND_COMPLETION => {
                if (result == null) result = .{ .cc = cc, .slot = @truncate(e.param & 0xFF) };
            },
            EV_PORT_STATUS => {},
            EV_TRANSFER => {},
            else => {},
        }

        advanceErdp();
    }
    return result;
}

fn advanceErdp() void {
    evt_ring[evt_dequeue].control = 0; // clear
    evt_dequeue = (evt_dequeue + 1) % RING_COUNT;
    if (evt_dequeue == 0) evt_cycle ^= 1;
    // Refresh ERDP so the controller knows we consumed events.
    if (rt_base == 0) return;
    const erdp_val: u64 = @intFromPtr(&evt_ring) + evt_dequeue * TRB_SIZE;
    wr32(rt_base + 0x38, @as(u32, @truncate(erdp_val & 0xFFFFFFF0)) | 0x8); // EHST bit
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------

fn enumerate() void {
    var p: u8 = 1;
    while (p <= max_ports) : (p += 1) {
        const ps = op.portsc(p);
        if ((ps.* & PORT_CCS) == 0) continue;

        const speed = (ps.* & PORT_SPEED_MASK) >> 10;
        serial.serialWrite("[XHCI] port ");
        serial.serialWriteDec(p);
        serial.serialWrite(": device present, speed=");
        serial.serialWriteDec(speed);
        serial.serialWrite("\n");

        resetPort(p);
        probePort(p, speed);
    }
}

fn resetPort(port1: u8) void {
    const ps = op.portsc(port1);
    ps.* |= PORT_RESET;
    spinMs(20);
    // Clear change bits (W1C).
    const ps2 = op.portsc(port1);
    ps2.* |= PORT_PRSC | PORT_PEC | PORT_WRC | PORT_CSC;
    spinMs(10);
}

// ---------------------------------------------------------------------------
// Control transfers (default pipe)
// ---------------------------------------------------------------------------

fn doControl(slot: u8, mps: u16, setup: [8]u8, data: ?[]u8) bool {
    // Three-stage transfer on EP0's ring — we reuse the command ring trick:
    // build a mini-ring inline inside ctx_page tail reserved area.
    const ctrl_ring: *[8]Trb = @ptrCast(ctx_page[3584..].ptr);
    @memset(ctrl_ring, std.mem.zeroes(Trb));

    var stage: usize = 0;
    ctrl_ring[stage] = .{
        .param = std.mem.readInt(u64, &setup, .little),
        .control = (TRB_SETUP_STAGE << TRB_TYPE_SHIFT) | TRB_IDT | (TRB_CYCLE),
        .status = 8,
    };
    stage += 1;

    if (data) |d| {
        ctrl_ring[stage] = .{
            .param = @intFromPtr(d.ptr),
            .status = @intCast(d.len),
            .control = (TRB_DATA_STAGE << TRB_TYPE_SHIFT) |
                (if (setup[0] & 0x80 != 0) @as(u32, 1 << 16) else 0), // DIR IN
        };
        stage += 1;
    }

    ctrl_ring[stage] = .{
        .param = 0,
        .status = 0,
        .control = (TRB_STATUS_STAGE << TRB_TYPE_SHIFT) | TRB_IOC |
            (if (data != null and setup[0] & 0x80 != 0) @as(u32, 0) else 1 << 16),
    };
    ctrl_ring[stage].setType(TRB_STATUS_STAGE);

    // Cycle bits: all stages carry the producer cycle; toggling happens per
    // ring wrap only, and this mini-ring never wraps.
    var i: usize = 0;
    while (i <= stage) : (i += 1) ctrl_ring[i].control |= TRB_CYCLE;

    // Kick EP0 doorbell (target = slot, endpoint 0 => target = slot*32 + 1).
    doorbellTarget(slot, 1);

    _ = mps;
    const res = waitForCommandLikeTransfer(slot) orelse return false;
    return res.cc == CC_SUCCESS;
}

fn doorbellTarget(slot: u8, ep: u8) void {
    const dboff = rd32(cap.base + 0x14) & ~@as(u32, 3);
    wr32(cap.base + dboff + @as(usize, slot) * 4, (@as(u32, ep) << 16) | 0);
}

/// Wait for a TRANSFER event belonging to `slot` (used by control pipes).
fn waitForCommandLikeTransfer(slot: u8) ?struct { cc: u32, slot: u8 } {
    var waited: usize = 0;
    while (waited < 3000) : (waited += 1) {
        var guard: usize = 0;
        while (guard < RING_COUNT) : (guard += 1) {
            const e = &evt_ring[evt_dequeue];
            if ((e.control & TRB_CYCLE) != evt_cycle) break;
            const etype = e.trbType();
            const cc = (e.status >> 24) & 0xFF;
            const ev_slot: u8 = @truncate(e.param & 0xFF);

            if (etype == EV_TRANSFER and ev_slot == slot) {
                advanceErdp();
                return .{ .cc = cc, .slot = slot };
            }
            if (etype == EV_COMMAND_COMPLETION) {
                advanceErdp();
                return .{ .cc = cc, .slot = ev_slot };
            }
            advanceErdp();
        }
        spinMs(1);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Per-port device bring-up
// ---------------------------------------------------------------------------

fn probePort(port1: u8, speed: u32) void {
    if (dev_count >= devices.len) return;

    // 1. Enable Slot
    pushCommand(.{ .control = (TRB_ENABLE_SLOT << TRB_TYPE_SHIFT) | TRB_IOC });
    const en = waitForCommandCompletion(500) orelse return;
    if (en.cc != CC_SUCCESS) {
        serial.serialWrite("[XHCI] EnableSlot failed\n");
        return;
    }
    const slot = en.slot;

    // 2. Input context: slot ctx + EP0 ctx (drop context 0, configure 1).
    @memset(ctx_page[0..64], 0); // input control area
    // Input control context: Dword0 drop=0 add=(bit0 slot)|(bit1 ep0)
    wr32(@intFromPtr(&ctx_page), (1 << 0) | (1 << 1));
    // Slot context (offset 32 within input ctx): speed, ctx entries 1, intr 0
    const slot_ctx = ctx_page[32..64];
    const sc: [*]volatile u32 = @ptrCast(slot_ctx.ptr);
    sc[0] = (@as(u32, speed) << 20) | (1 << 27); // ctx entries bit31? keep minimal
    // Route string 0; hub 0; port = port1; speed field [26:20]
    sc[1] = port1;
    // EP0 context at input ctx + 64: type Ctrl-BI(4), error 3, MPS 64
    const ep0 = ctx_page[64 .. 64 + 32];
    const e0: [*]volatile u32 = @ptrCast(ep0.ptr);
    e0[0] = (4 << 3) | (3 << 1); // EP type 4, max error 3
    e0[1] = 64; // MPS
    // Dequeue ptr = a fresh control ring inside our ctx tail (never wrapped)
    const ctrl_ring_phys = @intFromPtr(&ctx_page) + 3584;
    const e0q: *volatile u64 = @ptrCast(ep0.ptr + 8);
    e0q.* = ctrl_ring_phys | 1; // cycle 1

    // Copy input ctx into DCBAA slot pointer location expected by controller:
    // controller READS input ctx from the Input Context Pointer in the
    // Address Device TRB param — we pass ctx_page directly.

    pushCommand(.{
        .param = @intFromPtr(&ctx_page),
        .control = (TRB_ADDRESS_DEVICE << TRB_TYPE_SHIFT) | TRB_IOC,
        .status = slot,
    });
    const addr = waitForCommandCompletion(500) orelse return;
    if (addr.cc != CC_SUCCESS) {
        serial.serialWrite("[XHCI] AddressDevice failed cc=");
        serial.serialWriteDec(addr.cc);
        serial.serialWrite("\n");
        return;
    }

    // 3. Identify the device: GET_DESCRIPTOR(Device, 8) tells us class hints;
    //    QEMU usb-kbd/tablet are recognised by interface class later, but for
    //    simplicity identify via bDescriptor sniff of config blob length 64.
    var dev_desc: [18]u8 = .{0} ** 18;
    const setup_dev = [_]u8{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 };
    if (!doControl(slot, 64, setup_dev, dev_desc[0..18])) {
        serial.serialWrite("[XHCI] GET_DESCRIPTOR failed\n");
        return;
    }
    const vendor: u16 = std.mem.readInt(u16, dev_desc[8..10], .little);
    const product: u16 = std.mem.readInt(u16, dev_desc[10..12], .little);

    var cfg: [64]u8 = .{0} ** 64;
    const setup_cfg_len = [_]u8{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 0x09, 0x00 };
    if (!doControl(slot, 64, setup_cfg_len, cfg[0..9])) return;
    const cfg_total = std.mem.readInt(u16, cfg[2..4], .little);
    const want: u16 = @min(cfg_total, 64);
    const setup_cfg_full = [_]u8{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, @intCast(want & 0xFF), @intCast(want >> 8) };
    if (!doControl(slot, 64, setup_cfg_full, cfg[0..want])) return;

    // Walk config: find interface class HID (0x03) and its interrupt IN EP.
    var kind: HidDevKind = .none;
    var ep_addr: u8 = 0;
    var ep_mps: u16 = 8;
    var interval: u32 = 10;

    var off: usize = 0;
    var iface_hid = false;
    var iface_proto: u8 = 0;
    while (off + 2 <= want) {
        const blen = cfg[off];
        const btype = cfg[off + 1];
        if (blen < 2 or off + blen > want) break;
        if (btype == 0x04) { // interface descriptor
            iface_hid = cfg[off + 5] == 0x03; // bInterfaceClass
            iface_proto = cfg[off + 7]; // 1=keyboard 2=mouse (boot)
        } else if (btype == 0x05 and iface_hid) { // endpoint descriptor
            const attrs = cfg[off + 3];
            if (attrs & 3 == 3 and cfg[off + 2] & 0x80 != 0) { // interrupt IN
                ep_addr = cfg[off + 2];
                ep_mps = (@as(u16, cfg[off + 5]) << 8) | cfg[off + 4];
                interval = cfg[off + 6];
                kind = switch (iface_proto) {
                    1 => .keyboard,
                    2 => .tablet,
                    else => .none,
                };
                break;
            }
        }
        off += blen;
    }

    if (kind == .none or ep_addr == 0) {
        serial.serialWrite("[XHCI] slot ");
        serial.serialWriteDec(slot);
        serial.serialWrite(": non-HID or unsupported device (vend=0x");
        serial.serialWriteHex(vendor);
        serial.serialWrite(" prod=0x");
        serial.serialWriteHex(product);
        serial.serialWrite(")\n");
        return;
    }

    // 4. SET_PROTOCOL(boot) so reports follow the fixed 8-byte layout.
    const setup_proto = [_]u8{ 0x21, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    _ = doControl(slot, 64, setup_proto, null);
    const setup_idle = [_]u8{ 0x21, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    _ = doControl(slot, 64, setup_idle, null);

    // 5. Configure Endpoint: add EP1-in context to the input ctx.
    @memset(ctx_page[0..64], 0);
    wr32(@intFromPtr(&ctx_page), (@as(u32, 1) << 1) | (@as(u32, 1) << @intCast(ep_addr & 0x1F)));
    const sc2: [*]volatile u32 = @ptrCast(ctx_page[32..64].ptr);
    sc2[0] = (@as(u32, speed) << 20) | (1 << 27);
    sc2[1] = port1;

    const ep_in_idx: u8 = (ep_addr & 0x0F) * 2 + 1; // context index for IN ep
    const ep_ctx_off: usize = 64 + @as(usize, ep_in_idx - 1) * 32;
    const ec: [*]align(1) volatile u32 = @ptrCast(ctx_page[ep_ctx_off..].ptr);
    ec[0] = (3 << 3) | (3 << 1); // Interrupt-In = type 3
    ec[1] = ep_mps;
    ec[2] = interval;

    // Dedicated transfer ring for this endpoint.
    var ring_page: [4096]u8 align(4096) = .{0} ** 4096;
    const ring: *[RING_COUNT]Trb = @ptrCast(&ring_page);
    ring[RING_COUNT - 1] = .{
        .param = @intFromPtr(&ring_page),
        .control = (TRB_LINK << TRB_TYPE_SHIFT) | TRB_CYCLE,
    };
    const e0q2: *align(1) volatile u64 = @ptrCast(ctx_page[ep_ctx_off .. ep_ctx_off + 32].ptr + 8);
    e0q2.* = @intFromPtr(&ring_page) | 1;

    pushCommand(.{
        .param = @intFromPtr(&ctx_page),
        .control = (TRB_CONFIGURE_ENDPOINT << TRB_TYPE_SHIFT) | TRB_IOC,
        .status = slot,
    });
    const cfg_res = waitForCommandCompletion(500) orelse return;
    if (cfg_res.cc != CC_SUCCESS) {
        serial.serialWrite("[XHCI] ConfigureEndpoint failed\n");
        return;
    }

    // Persist the ring page into one of our four slots' storage: we keep a
    // static pool since QEMU attaches at most two HID devices.
    persistRing(dev_count, ring_page);

    devices[dev_count] = .{
        .slot = slot,
        .kind = kind,
        .ep_addr = ep_addr,
        .ep_mps = ep_mps,
        .interval = interval,
        .ring_phys = @intFromPtr(&ring_pages[dev_count]),
        .enqueue = 0,
        .cycle = 1,
        .vendor = vendor,
        .product = product,
    };

    // Post the first OUT-of-our-hands IN transfer: an empty NORMAL TRB with
    // IOC pointing at our report buffer.
    postInTransfer(&devices[dev_count]);

    serial.serialWrite("[XHCI] HID ");
    serial.serialWrite(switch (kind) {
        .keyboard => "keyboard",
        .tablet => "tablet",
        .none => "?",
    });
    serial.serialWrite(" on slot ");
    serial.serialWriteDec(slot);
    serial.serialWrite(" (vend=0x");
    serial.serialWriteHex(vendor);
    serial.serialWrite(" prod=0x");
    serial.serialWriteHex(product);
    serial.serialWrite(")\n");

    dev_count += 1;
}

// Static storage for up to four transfer rings (kept alive for DMA).
var ring_pages: [4][4096]u8 align(4096) = .{.{0} ** 4096} ** 4;

fn persistRing(idx: usize, page: [4096]u8) void {
    @memcpy(&ring_pages[idx], &page);
}

fn postInTransfer(d: *DevInfo) void {
    const ring: *[RING_COUNT]Trb = @ptrFromInt(d.ring_phys);
    const buf: []u8 = if (d.kind == .keyboard) &kbd_report else &tab_report;

    ring[d.enqueue] = .{
        .param = @intFromPtr(buf.ptr),
        .status = (@as(u32, @intCast(buf.len)) & 0x1FFFF) << 16,
        .control = (TRB_NORMAL << TRB_TYPE_SHIFT) | TRB_IOC | d.cycle,
    };
    d.enqueue = (d.enqueue + 1) % (RING_COUNT - 1);
    if (d.enqueue == 0) d.cycle ^= 1;

    doorbellTarget(d.slot, d.ep_addr & 0x0F);
}

// ---------------------------------------------------------------------------
// Report decoding + public polling
// ---------------------------------------------------------------------------

var last_kbd: [8]u8 = .{0} ** 8;

fn decodeKeyboard(rep: *const [8]u8) void {
    // Modifiers: L/R Ctrl/Shift/Alt/GUI — report shift for letters/punct.
    const shift = (rep[0] & 0x22) != 0;

    // Key-up detection against previous report keeps things simple: we emit
    // characters on PRESS only.
    var i: usize = 2;
    while (i < 8) : (i += 1) {
        const k = rep[i];
        var was_down = false;
        for (last_kbd[2..]) |pk| {
            if (pk == k) was_down = true;
        }
        if (k == 0 or was_down) continue;
        if (asciiFor(k, shift)) |ch| {
            @import("keyboard.zig").injectChar(ch);
        }
    }
    last_kbd = rep.*;
}

fn asciiFor(code: u8, shift: bool) ?u8 {
    const lower = [_]u8{
        0,    0,   '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0,   0,
        'q',  'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,  'a', 's',
        'd',  'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,   '\\', 'z', 'x', 'c', 'v',
        'b',  'n', 'm', ',', '.', '/', 0,   '*', 0,   ' ', 0,
    };
    if (code >= lower.len) return null;
    var ch = lower[code];
    if (ch == 0) return null;
    if (shift) {
        if (ch >= '1' and ch <= '9') {
            const upper = [_]u8{ '!', '@', '#', '$', '%', '^', '&', '*', '(' };
            ch = upper[ch - '1'];
        } else switch (ch) {
            '0' => ch = ')',
            '-' => ch = '_',
            '=' => ch = '+',
            '[' => ch = '{',
            ']' => ch = '}',
            '\\' => ch = '|',
            ';' => ch = ':',
            '\'' => ch = '"',
            ',' => ch = '<',
            '.' => ch = '>',
            '/' => ch = '?',
            '`' => ch = '~',
            else => {},
        }
        if (ch >= 'a' and ch <= 'z') ch -= 32;
    }
    return ch;
}

fn decodeTablet(rep: *const [8]u8) void {
    const mouse = @import("mouse.zig");
    const btn = rep[0] & 0x07;
    const x = @as(u32, rep[1]) | (@as(u32, rep[2]) << 8);
    const y = @as(u32, rep[3]) | (@as(u32, rep[4]) << 8);
    mouse.usbUpdate(@intCast(x), @intCast(y), btn & 1 != 0, btn & 2 != 0, btn & 4 != 0);
}

/// Called from the scheduler tick (100 Hz): drain events, decode fresh
/// reports, and re-arm interrupt transfers.
pub fn pollHid() void {
    if (!ready) return;

    var guard: usize = 0;
    while (guard < RING_COUNT) : (guard += 1) {
        const e = &evt_ring[evt_dequeue];
        if ((e.control & TRB_CYCLE) != evt_cycle) break;

        const etype = e.trbType();
        if (etype == EV_TRANSFER) {
            const ev_slot: u8 = @truncate(e.param & 0xFF);
            for (&devices) |*d| {
                if (d.slot == ev_slot and d.kind != .none) {
                    switch (d.kind) {
                        .keyboard => decodeKeyboard(&kbd_report),
                        .tablet => decodeTablet(&tab_report),
                        .none => {},
                    }
                    postInTransfer(d);
                    break;
                }
            }
        } else if (etype == EV_PORT_STATUS) {
            // Re-enumerate lazily: mark for next tick.
        }
        advanceErdp();
    }
}
