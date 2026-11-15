//! The Host Controller Interface protocol core.
//!
//! Ported from the Linux kernel's Bluetooth stack:
//!
//!   * `include/net/bluetooth/hci.h`     - the packet formats, the opcodes
//!     and the event codes.
//!   * `include/net/bluetooth/hci_core.h` - the controller state machine.
//!   * `net/bluetooth/hci_core.c`         - the command plumbing: the reset
//!     sequence, the inquiry procedure and the event dispatch.
//!
//! The transport is deliberately separate from the protocol: `btusb.zig`
//! speaks HCI over USB and `vhci.zig` provides a virtual controller, but
//! both hand the core the same thing - a complete HCI command packet and a
//! stream of HCI event packets.
//!
//! Everything here is byte-for-byte what the Bluetooth specification says
//! and what Linux sends, because a Bluetooth controller does not care what
//! operating system is talking to it.

/// The largest HCI packet this implementation handles.  The specification
/// allows 4096 bytes of ACL data; the packets the core itself builds are
/// far smaller.
pub const MAX_HCI_PACKET: usize = 64;

/// A Bluetooth device address (BD_ADDR), least significant byte first - the
/// order the specification and Linux use on the wire.
pub const BdAddr = [6]u8;

/// The opcode of an HCI command: the group (OGF) in the high bits and the
/// command (OCF) in the low bits.
pub const Opcode = u16;

/// The command groups (Linux's `HCI_OGF_*`).
pub const Ogf = struct {
    pub const link_control: Opcode = 0x01;
    pub const link_policy: Opcode = 0x02;
    pub const controller_base: Opcode = 0x03;
    pub const info_param: Opcode = 0x04;
    pub const status_param: Opcode = 0x05;
    pub const le_control: Opcode = 0x08;
    pub const vendor: Opcode = 0x3F;
};

/// The commands the core uses.  The names follow Linux's `HCI_OP_*` macros.
pub const Op = struct {
    pub const inquiry: Opcode = 0x0401;
    pub const inquiry_cancel: Opcode = 0x0402;
    pub const create_connection: Opcode = 0x0405;
    pub const disconnect: Opcode = 0x0406;
    pub const reset: Opcode = 0x0C03;
    pub const write_scan_enable: Opcode = 0x0C1A;
    pub const read_local_version: Opcode = 0x1001;
    pub const read_bd_addr: Opcode = 0x1009;
    pub const le_set_scan_enable: Opcode = 0x200C;
};

/// The event codes the core reacts to (Linux's `HCI_EV_*`).
pub const Evt = struct {
    pub const inquiry_complete: u8 = 0x01;
    pub const inquiry_result: u8 = 0x02;
    pub const connection_complete: u8 = 0x03;
    pub const disconnection_complete: u8 = 0x05;
    pub const command_complete: u8 = 0x0E;
    pub const command_status: u8 = 0x0F;
    pub const number_of_completed_packets: u8 = 0x13;
    pub const inquiry_result_with_rssi: u8 = 0x22;
};

/// The status codes the specification defines.  Only the ones that carry
/// meaning here are named; the rest keep their numeric value.
pub const Status = struct {
    pub const success: u8 = 0x00;
    pub const unknown_command: u8 = 0x01;
    pub const unknown_connection: u8 = 0x02;
    pub const authentication_failure: u8 = 0x05;
    pub const connection_timeout: u8 = 0x08;
    pub const unsupported_feature: u8 = 0x11;
};

/// The controller's state, as in Linux's `hci_dev->state`.
pub const State = enum {
    /// The controller is off.
    down,
    /// A reset is in flight.
    resetting,
    /// The controller is up and accepts commands.
    up,
};

/// The transport the protocol core talks through.
///
/// `send` takes a complete HCI command packet (the opcode, the length and
/// the parameters - no H4 type byte; the transport adds whatever framing
/// its hardware needs).  `recv` returns one HCI event packet.
///
/// The defaults are a transport that does nothing: a controller that has no
/// transport yet must still be a valid value, because the core lives in a
/// global and a global declared `undefined` never gets the field defaults.
pub const Transport = struct {
    ctx: ?*anyopaque = null,
    send: *const fn (ctx: ?*anyopaque, data: []const u8) bool = noSend,
    recv: *const fn (ctx: ?*anyopaque, buf: []u8) ?usize = noRecv,

    fn noSend(ctx: ?*anyopaque, data: []const u8) bool {
        _ = ctx;
        _ = data;
        return false;
    }

    fn noRecv(ctx: ?*anyopaque, buf: []u8) ?usize {
        _ = ctx;
        _ = buf;
        return null;
    }
};

/// The controller version, from `READ_LOCAL_VERSION`.
pub const Version = struct {
    hci_version: u8 = 0,
    hci_subversion: u16 = 0,
    lmp_version: u8 = 0,
    manufacturer: u16 = 0,
};

/// A remote device seen during an inquiry.
pub const Peer = struct {
    addr: BdAddr = @splat(0),
    page_scan_rep_mode: u8 = 0,
    reserved: u8 = 0,
    clock_offset: u16 = 0,
    class_of_device: [3]u8 = @splat(0),
    /// The signal strength, when the peer answered the "with RSSI" variant
    /// of the inquiry result event.
    rssi: i8 = 0,
};

pub const MAX_PEERS: usize = 16;

/// The protocol core: the state machine, the command builder and the event
/// dispatch.
pub const Controller = struct {
    transport: Transport = .{},
    state: State = .down,
    addr: BdAddr = @splat(0),
    version: Version = .{},
    /// The peers found by the last inquiry.
    peers: [MAX_PEERS]Peer = @splat(.{}),
    peer_count: usize = 0,
    /// The status of the last command that completed.
    last_status: u8 = Status.success,
    /// The opcode of the command that completed last.
    last_opcode: Opcode = 0,
    /// True when a command completion has been seen.
    completed: bool = false,
    /// The status of the last inquiry.
    inquiry_status: u8 = 0,
    /// True once the controller reported that the inquiry is over.
    inquiry_done: bool = false,
    /// Set when the controller reported that it went down.
    hung: bool = false,
    /// True to write the driver's progress to the serial log.
    verbose: bool = true,

    /// The scratch buffer a command is built in.
    cmd_buf: [MAX_HCI_PACKET]u8 = @splat(0),

    pub fn init(self: *Controller, transport: Transport) bool {
        self.transport = transport;
        self.state = .down;
        return self.reset();
    }

    /// The reset sequence, from Linux's `hci_reset` in `hci_core.c`:
    /// reset the controller, then read its address and version.
    pub fn reset(self: *Controller) bool {
        self.state = .resetting;
        self.hung = false;
        self.completed = false;

        if (!self.sendCommand(Op.reset, &[_]u8{})) {
            self.state = .down;
            return false;
        }
        if (!self.waitForCommand(Op.reset) or self.last_status != Status.success) {
            self.state = .down;
            return false;
        }

        // READ_BD_ADDR - Linux reads it right after the reset, because the
        // address is what every later command refers to.
        self.completed = false;
        if (!self.sendCommand(Op.read_bd_addr, &[_]u8{})) {
            self.state = .down;
            return false;
        }
        if (!self.waitForCommand(Op.read_bd_addr) or self.last_status != Status.success) {
            self.state = .down;
            return false;
        }

        // The version is informational: a controller that does not answer
        // is still usable.
        self.completed = false;
        _ = self.sendCommand(Op.read_local_version, &[_]u8{});

        self.state = .up;
        return true;
    }

    /// Start an inquiry: the LAP, the inquiry length in 1.28 s units and
    /// the number of responses wanted.  This is Linux's
    /// `hci_perform_inquiry` (`net/bluetooth/hci_core.c`).
    pub fn inquiry(self: *Controller, length: u8, num_rsp: u8) bool {
        if (self.state != .up) return false;
        self.peer_count = 0;
        self.inquiry_done = false;

        // struct hci_cp_inquiry { __u8 lap[3]; __u8 length; __u8 num_rsp; }
        var params: [5]u8 = @splat(0);
        params[3] = length;
        params[4] = num_rsp;

        return self.sendCommand(Op.inquiry, &params);
    }

    /// Enable or disable the inquiry scan (Linux's `hci_write_scan_enable`).
    pub fn writeScanEnable(self: *Controller, enable: bool) bool {
        if (self.state != .up) return false;
        // struct hci_cp_write_scan_enable { __u8 scan_enable; }
        const params = [_]u8{if (enable) 1 else 0};
        return self.sendCommand(Op.write_scan_enable, &params);
    }

    /// Build and send one HCI command packet.
    ///
    /// The packet is the command header followed by the parameters:
    ///
    ///     struct hci_command_hdr { __le16 opcode; __u8 plen; }
    pub fn sendCommand(self: *Controller, opcode: Opcode, params: []const u8) bool {
        if (params.len > MAX_HCI_PACKET - 3) return false;

        self.cmd_buf[0] = @truncate(opcode & 0xFF);
        self.cmd_buf[1] = @truncate(opcode >> 8);
        self.cmd_buf[2] = @truncate(params.len);
        @memcpy(self.cmd_buf[3 .. 3 + params.len], params);

        return self.transport.send(self.transport.ctx, self.cmd_buf[0 .. 3 + params.len]);
    }

    /// Read the pending events and dispatch them.
    ///
    /// Linux reads the event socket in the work queue; here the caller
    /// decides when to poll, which keeps the driver free of threads.
    pub fn poll(self: *Controller) void {
        var buf: [MAX_HCI_PACKET]u8 = @splat(0);
        var guard: u32 = 0;
        while (guard < 32) : (guard += 1) {
            const len = self.transport.recv(self.transport.ctx, &buf) orelse return;
            if (len < 2) continue;
            self.handleEvent(buf[0..len]);
        }
    }

    /// Dispatch one HCI event packet.
    ///
    /// The event header is:
    ///
    ///     struct hci_event_hdr { __u8 evt; __u8 plen; }
    pub fn handleEvent(self: *Controller, event: []const u8) void {
        if (event.len < 2) return;
        const code = event[0];
        const params = event[2..];

        switch (code) {
            Evt.command_complete => self.handleCommandComplete(params),
            Evt.command_status => self.handleCommandStatus(params),
            Evt.inquiry_complete => self.handleInquiryComplete(params),
            Evt.inquiry_result => self.handleInquiryResult(params, false),
            Evt.inquiry_result_with_rssi => self.handleInquiryResult(params, true),
            else => {},
        }
    }

    /// `struct hci_ev_cmd_complete { __u8 ncmd; __u16 opcode; __u8 plen;
    /// __u8 status; __u8 data[252]; }`
    fn handleCommandComplete(self: *Controller, params: []const u8) void {
        if (params.len < 5) return;
        const opcode = @as(Opcode, params[1]) | (@as(Opcode, params[2]) << 8);

        self.last_status = params[4];
        self.last_opcode = opcode;
        self.completed = true;

        if (opcode == Op.read_bd_addr and params.len >= 11) {
            // The address follows the status: six bytes, little endian.
            @memcpy(self.addr[0..6], params[5..11]);
        }
        if (opcode == Op.read_local_version and params.len >= 11) {
            // struct hci_cp_read_local_version { __u8 hci_version; __u16
            // hci_subversion; __u8 lmp_version; __u16 manufacturer; }
            self.version.hci_version = params[5];
            self.version.hci_subversion = @as(u16, params[6]) | (@as(u16, params[7]) << 8);
            self.version.lmp_version = params[8];
            self.version.manufacturer = @as(u16, params[9]) | (@as(u16, params[10]) << 8);
        }
    }

    /// `struct hci_ev_cmd_status { __u8 status; __u8 num_hci_cmd_packets;
    /// __u16 opcode; }`
    fn handleCommandStatus(self: *Controller, params: []const u8) void {
        if (params.len < 4) return;
        self.last_status = params[0];
        self.last_opcode = @as(Opcode, params[2]) | (@as(Opcode, params[3]) << 8);
        self.completed = true;
    }

    /// `struct hci_ev_inquiry_complete { __u8 status; }`
    fn handleInquiryComplete(self: *Controller, params: []const u8) void {
        if (params.len < 1) return;
        self.inquiry_status = params[0];
        self.inquiry_done = true;

        if (self.verbose) {
            const serial = @import("../../system/serial.zig");
            serial.serialWrite("[BT] Inquiry complete, status ");
            serial.serialWriteDec(params[0]);
            serial.serialWrite(", ");
            serial.serialWriteDec(self.peer_count);
            serial.serialWrite(" peer(s)\n");
        }
    }

    /// `struct hci_cp_inquiry_result { __u8 nbr_of_rsp; bdaddr_t bdaddr;
    /// __u8 psrmode; __u8 pscanmode; __u8 pscan_rep_mode; __u16
    /// clock_offset; }`
    ///
    /// The "with RSSI" variant appends the RSSI value; it is parsed the
    /// same way, the extra byte is simply read as well.
    fn handleInquiryResult(self: *Controller, params: []const u8, with_rssi: bool) void {
        if (params.len < 12) return;

        // Linux reads the whole result array in one go; here the event
        // carries one result per event, so one peer per event.
        if (self.peer_count >= MAX_PEERS) return;

        var peer = Peer{};
        @memcpy(peer.addr[0..6], params[1..7]);
        peer.page_scan_rep_mode = params[9];
        peer.clock_offset = @as(u16, params[10]) | (@as(u16, params[11]) << 8);
        if (with_rssi and params.len >= 13) {
            // The RSSI is a signed byte after the clock offset.
            peer.rssi = @as(i8, @bitCast(params[12]));
        }
        self.peers[self.peer_count] = peer;
        self.peer_count += 1;

        if (self.verbose) {
            const serial = @import("../../system/serial.zig");
            var buf: [32]u8 = undefined;
            serial.serialWrite("[BT] Peer found: ");
            serial.serialWrite(formatBdAddr(peer.addr, &buf));
            serial.serialWrite("\n");
        }
    }

    /// Wait for the completion of one command.
    ///
    /// Linux waits on a completion event; here the caller polls, so the
    /// wait is a bounded loop over the transport's event queue.
    fn waitForCommand(self: *Controller, opcode: Opcode) bool {
        var guard: u32 = 0;
        while (guard < 200) : (guard += 1) {
            if (self.completed and self.last_opcode == opcode) return true;
            self.poll();
            spinWait();
        }
        return false;
    }
};

fn spinWait() void {
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        asm volatile ("pause" ::: .{ .memory = true });
    }
}

/// Print a BD_ADDR the way Linux's `bacpy` does: the most significant byte
/// first, in upper case, separated by colons.
pub fn formatBdAddr(addr: BdAddr, buf: []u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < 6) : (i += 1) {
        if (n + 3 > buf.len) break;
        const byte = addr[5 - i];
        buf[n] = hexDigit(byte >> 4);
        buf[n + 1] = hexDigit(byte & 0xF);
        n += 2;
        if (i != 5 and n < buf.len) {
            buf[n] = ':';
            n += 1;
        }
    }
    return buf[0..n];
}

fn hexDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'A' + (v - 10);
}
