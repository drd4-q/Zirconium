//! A guest driver for the ZVP - the hypervisor's own device.
//!
//! This program runs in ring 3 and behaves exactly as a guest kernel's
//! driver would: it finds the device, checks that it is there, asks the
//! hypervisor what machine it has been given, and reports what it found
//! back.
//!
//! It is the proof that the device interface works end to end.  The same
//! code will run unchanged under the CPU emulator, where the device's
//! registers are reached through a guest page table instead of a mapping
//! the hypervisor set up.
//!
//! The registers are at REGS_VADDR and the shared window at WINDOW_VADDR -
//! the addresses `proto.zig` defines and the hypervisor maps.

const proto = @import("kvm_proto");

fn syscall3(num: u64, arg1: u64, arg2: u64, arg3: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn write(fd: u64, msg: []const u8) void {
    _ = syscall3(1, fd, @intFromPtr(msg.ptr), msg.len);
}

fn writeDec(fd: u64, value: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    if (v == 0) {
        write(fd, "0");
        return;
    }
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    write(fd, buf[i..]);
}

fn writeHex(fd: u64, value: u64) void {
    const hex = "0123456789ABCDEF";
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        // The most significant nibble goes first, so it belongs at the
        // *start* of the buffer.
        buf[15 - i] = hex[(value >> @intCast(i * 4)) & 0xF];
    }
    write(fd, buf[0..]);
}

fn exit(code: u64) noreturn {
    _ = syscall3(60, code, 0, 0);
    while (true) {}
}

// ─── The device ─────────────────────────────────────────────────────

const regs: [*]volatile u32 = @ptrFromInt(proto.REGS_VADDR);
const window: [*]volatile u8 = @ptrFromInt(proto.WINDOW_VADDR);

fn rd(offset: usize) u32 {
    return regs[offset / 4];
}

fn wr(offset: usize, value: u32) void {
    regs[offset / 4] = value;
}

/// The command sequence the driver rings.
var sequence: u32 = 0;

/// Issue a command and wait for the hypervisor to answer it.
///
/// The protocol is a doorbell: the driver writes its arguments, writes the
/// command, and then rings the doorbell with the next sequence number.  It
/// waits for the hypervisor to echo that number back, so a stale answer
/// from the previous command can never be mistaken for this one.
fn command(cmd: u32, arg0: u32, arg1: u32) u32 {
    sequence +%= 1;
    const mine = sequence;

    wr(proto.REG_ARG0, arg0);
    wr(proto.REG_ARG1, arg1);
    wr(proto.REG_CMD, cmd);
    wr(proto.REG_DOORBELL, mine);

    var spins: u32 = 0;
    while (spins < 20_000_000) : (spins += 1) {
        if (rd(proto.REG_SERVICED) == mine) {
            if (rd(proto.REG_STATUS) == proto.STATUS_ERROR) return 0xFFFF_FFFF;
            return rd(proto.REG_RESULT0);
        }
    }
    return 0xFFFF_FFFF;
}

pub export fn _start() callconv(.c) noreturn {
    const out: u64 = 3; // the serial log

    // ── Find the device ──────────────────────────────────────────
    const magic = rd(proto.REG_MAGIC);
    if (magic != proto.MAGIC) {
        write(out, "[GUEST] No ZVP device: magic was 0x");
        writeHex(out, magic);
        write(out, "\n");
        exit(1);
    }
    write(out, "[GUEST] ZVP device found, version ");
    writeDec(out, rd(proto.REG_VERSION));
    write(out, "\n");

    // The device presents itself as an ordinary device from an ordinary
    // vendor.  A guest driver binds to that vendor's driver and never
    // learns it is talking to a hypervisor.
    write(out, "[GUEST] PCI device ");
    writeHex(out, rd(proto.REG_PCI_VENDOR));
    write(out, ":");
    writeHex(out, rd(proto.REG_PCI_DEVICE));
    write(out, " machine ");
    writeDec(out, rd(proto.REG_MACHINE_INDEX));
    write(out, "\n");

    // ── Ping ─────────────────────────────────────────────────────
    const pong = command(proto.CMD_PING, 0, 0);
    if (pong != 0x50494E47) {
        write(out, "[GUEST] PING failed: 0x");
        writeHex(out, pong);
        write(out, "\n");
        exit(1);
    }
    write(out, "[GUEST] PING ok\n");

    // ── Ask what machine we have been given ──────────────────────
    const blob_len = command(proto.CMD_IDENTITY, 0, 0);
    if (blob_len == 0 or blob_len > proto.IDENTITY_BLOB_SIZE) {
        write(out, "[GUEST] IDENTITY failed: ");
        writeDec(out, blob_len);
        write(out, "\n");
        exit(1);
    }
    write(out, "[GUEST] Identity blob: ");
    writeDec(out, blob_len);
    write(out, " bytes\n");

    // The blob's layout is fixed and little-endian; the first four fields
    // are the PCI vendor and device IDs.
    const vendor = readLe32(0);
    const device = readLe32(4);
    write(out, "[GUEST]   vendor=");
    writeHex(out, vendor);
    write(out, " device=");
    writeHex(out, device);
    write(out, "\n");

    // Field 12 is the hypervisor-present flag.  It must be clear: a guest
    // that can see it knows it is virtualised.
    const hypervisor_bit = readLe32(44);
    if (hypervisor_bit != 0) {
        write(out, "[GUEST] ERROR: hypervisor bit is set\n");
        exit(1);
    }
    write(out, "[GUEST]   hypervisor-present bit: clear\n");

    // ── Report what this "machine" looks like ────────────────────
    // A real driver would probe the interrupt controllers and the PCI bus
    // and report what it found; the hypervisor uses that to re-choose the
    // machine it should be presenting.
    _ = command(proto.CMD_OBSERVE, proto.OBS_8259_PIC, 1);
    _ = command(proto.CMD_OBSERVE, proto.OBS_PCI, 1);
    _ = command(proto.CMD_OBSERVE, proto.OBS_SSE2, 1);
    const observed = command(proto.CMD_OBSERVE, 0, 0);
    write(out, "[GUEST]   reported observations: 0x");
    writeHex(out, observed);
    write(out, "\n");

    // ── Post a message to the hypervisor ──────────────────────────
    const msg = "[GUEST] hello from the guest driver";
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        window[i] = msg[i];
    }
    window[msg.len] = 0;
    const posted = command(proto.CMD_POST, 0, 0);
    write(out, "[GUEST] Posted ");
    writeDec(out, posted);
    write(out, " bytes to the hypervisor\n");

    // ── The accent colour ─────────────────────────────────────────
    _ = command(proto.CMD_SET_ACCENT, 0x00FF8844, 0);
    write(out, "[GUEST] Accent colour set\n");

    write(out, "[GUEST] ZVP driver test PASSED\n");
    exit(0);
}

inline fn readLe32(at: usize) u32 {
    const p: [*]volatile u8 = @ptrFromInt(proto.WINDOW_VADDR);
    return @as(u32, p[at]) |
        (@as(u32, p[at + 1]) << 8) |
        (@as(u32, p[at + 2]) << 16) |
        (@as(u32, p[at + 3]) << 24);
}
