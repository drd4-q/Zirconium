//! A virtual Bluetooth controller.
//!
//! Ported from the Linux kernel's `drivers/bluetooth/hci_vhci.c`, which
//! provides a virtual HCI transport: the Bluetooth stack sends its packets
//! to a character device and the other end answers.  Linux leaves the
//! answering to userspace; here the controller is emulated in the kernel,
//! so that the protocol core has something to talk to and so that a guest
//! of the hypervisor can be handed a Bluetooth controller.
//!
//! The emulated controller answers the commands a controller has to answer
//! during the bring-up sequence, and it runs an inquiry that finds a couple
//! of peers, so the whole path - command, event, inquiry result, inquiry
//! complete - is exercised.

const serial = @import("../../system/serial.zig");
const hci = @import("hci.zig");

/// The number of events the virtual controller can queue.
const EVENT_QUEUE_SIZE: usize = 16;

/// The peers the virtual controller "finds" during an inquiry.
const FAKE_PEERS = [_]hci.BdAddr{
    // A plausible-looking, locally administered address.
    .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 },
    .{ 0x00, 0x1A, 0x7D, 0xDA, 0x71, 0x17 },
};

/// The address the virtual controller reports.
///
/// It is assigned explicitly in `init()` rather than left to the field
/// default: the controller lives in a global that is declared `undefined`,
/// and an undefined global does not get the field defaults.
pub const DEFAULT_ADDR: hci.BdAddr = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };

/// The virtual controller.
pub const Controller = struct {
    /// The address the controller reports.
    addr: hci.BdAddr = DEFAULT_ADDR,
    /// The HCI version the controller reports (Linux's `HCI_VERSION`).
    version: u8 = 0x0C, // 12: Bluetooth 4.6
    manufacturer: u16 = 0x000F, // the "Broadcom" id Linux uses in its tests

    /// The event queue.
    events: [EVENT_QUEUE_SIZE][hci.MAX_HCI_PACKET]u8 = @splat(@splat(0)),
    event_len: [EVENT_QUEUE_SIZE]u8 = @splat(0),
    event_head: usize = 0,
    event_tail: usize = 0,
    event_count: usize = 0,

    /// The protocol core that drives this controller.
    core: hci.Controller = .{},

    /// True once the core has been attached.
    ready: bool = false,

    pub fn init(self: *Controller) bool {
        // The controller lives in a global that is declared `undefined`, so
        // the fields that matter are set here rather than left to their
        // defaults.
        self.addr = DEFAULT_ADDR;
        self.version = 0x0C;
        self.manufacturer = 0x000F;

        const transport = hci.Transport{
            .ctx = @ptrCast(self),
            .send = send,
            .recv = recv,
        };
        self.ready = true;
        return self.core.init(transport);
    }

    /// Queue one event packet.
    fn pushEvent(self: *Controller, event: []const u8) void {
        if (event.len == 0 or event.len > hci.MAX_HCI_PACKET) return;

        if (self.event_count == EVENT_QUEUE_SIZE) {
            self.event_tail = (self.event_tail + 1) % EVENT_QUEUE_SIZE;
            self.event_count -= 1;
        }

        const slot = self.event_head;
        @memcpy(self.events[slot][0..event.len], event);
        self.event_len[slot] = @intCast(event.len);
        self.event_head = (self.event_head + 1) % EVENT_QUEUE_SIZE;
        self.event_count += 1;
    }

    /// The command complete event.
    ///
    ///     struct hci_ev_cmd_complete { __u8 ncmd; __u16 opcode; __u8 plen;
    ///     __u8 status; ... }
    fn pushCommandComplete(self: *Controller, opcode: hci.Opcode, status: u8, payload: []const u8) void {
        var event: [hci.MAX_HCI_PACKET]u8 = @splat(0);
        event[0] = hci.Evt.command_complete;
        event[1] = @intCast(4 + payload.len);
        event[2] = 1; // one command
        event[3] = @truncate(opcode & 0xFF);
        event[4] = @truncate(opcode >> 8);
        event[5] = @intCast(payload.len);
        event[6] = status;
        if (payload.len > 0) {
            @memcpy(event[7 .. 7 + payload.len], payload);
        }
        self.pushEvent(event[0 .. 7 + payload.len]);
    }

    /// The command status event, sent for the commands that take a while.
    ///
    ///     struct hci_ev_cmd_status { __u8 status; __u8 num_hci_cmd_packets;
    ///     __u16 opcode; }
    fn pushCommandStatus(self: *Controller, opcode: hci.Opcode, status: u8) void {
        var event: [hci.MAX_HCI_PACKET]u8 = @splat(0);
        event[0] = hci.Evt.command_status;
        event[1] = 4;
        event[2] = status;
        event[3] = 1; // one command can still be sent
        event[4] = @truncate(opcode & 0xFF);
        event[5] = @truncate(opcode >> 8);
        self.pushEvent(event[0..6]);
    }

    /// Handle one command, exactly as a controller would.
    fn handleCommand(self: *Controller, opcode: hci.Opcode, params: []const u8) void {
        switch (opcode) {
            hci.Op.reset => {
                // A reset cancels everything that was in flight.
                self.event_head = 0;
                self.event_tail = 0;
                self.event_count = 0;
                self.pushCommandComplete(opcode, hci.Status.success, &[_]u8{});
            },
            hci.Op.read_bd_addr => {
                self.pushCommandComplete(opcode, hci.Status.success, &self.addr);
            },
            hci.Op.read_local_version => {
                // struct hci_cp_read_local_version { __u8 hci_version; __u16
                // hci_subversion; __u8 lmp_version; __u16 manufacturer; }
                var payload: [6]u8 = @splat(0);
                payload[0] = self.version;
                payload[1] = 0x00;
                payload[2] = 0x00;
                payload[3] = self.version; // the LMP version follows the HCI one
                payload[4] = @truncate(self.manufacturer & 0xFF);
                payload[5] = @truncate(self.manufacturer >> 8);
                self.pushCommandComplete(opcode, hci.Status.success, &payload);
            },
            hci.Op.write_scan_enable => {
                self.pushCommandComplete(opcode, hci.Status.success, &[_]u8{});
            },
            hci.Op.inquiry => {
                // The inquiry takes a moment: the controller answers with a
                // status first, then the results, then the completion.
                self.pushCommandStatus(opcode, hci.Status.success);
                self.pushInquiryResults();
                self.pushInquiryComplete(hci.Status.success);
            },
            hci.Op.inquiry_cancel => {
                self.pushCommandComplete(opcode, hci.Status.success, &[_]u8{});
            },
            else => {
                // An unknown command is refused, exactly as the
                // specification requires.
                self.pushCommandComplete(opcode, hci.Status.unknown_command, &[_]u8{});
            },
        }
        _ = params;
    }

    /// The inquiry result events.
    ///
    ///     struct hci_cp_inquiry_result { __u8 nbr_of_rsp; bdaddr_t bdaddr;
    ///     __u8 psrmode; __u8 pscanmode; __u8 pscan_rep_mode; __u16
    ///     clock_offset; }
    fn pushInquiryResults(self: *Controller) void {
        for (FAKE_PEERS) |peer| {
            var event: [hci.MAX_HCI_PACKET]u8 = @splat(0);
            event[0] = hci.Evt.inquiry_result;
            event[1] = 12; // the parameter length
            event[2] = 1; // one response in this event
            @memcpy(event[3..9], &peer);
            event[9] = 0; // the page scan repetition mode
            event[10] = 0; // the page scan mode
            event[11] = 1; // the page scan reply mode
            event[12] = 0; // the clock offset
            event[13] = 0;
            self.pushEvent(event[0..14]);
        }
    }

    /// The inquiry complete event.
    fn pushInquiryComplete(self: *Controller, status: u8) void {
        var event: [hci.MAX_HCI_PACKET]u8 = @splat(0);
        event[0] = hci.Evt.inquiry_complete;
        event[1] = 1;
        event[2] = status;
        self.pushEvent(event[0..3]);
    }
};

/// The transport's send: hand the command to the emulated controller.
fn send(ctx: ?*anyopaque, data: []const u8) bool {
    const self: *Controller = @ptrCast(@alignCast(ctx orelse return false));
    if (data.len < 3) return false;

    const opcode = @as(hci.Opcode, data[0]) | (@as(hci.Opcode, data[1]) << 8);
    const plen = data[2];
    if (3 + plen > data.len) return false;

    self.handleCommand(opcode, data[3 .. 3 + plen]);
    return true;
}

/// The transport's receive: take the next queued event.
fn recv(ctx: ?*anyopaque, buf: []u8) ?usize {
    const self: *Controller = @ptrCast(@alignCast(ctx orelse return null));
    if (self.event_count == 0) return null;

    const len = self.event_len[self.event_tail];
    const n = @min(len, buf.len);
    @memcpy(buf[0..n], self.events[self.event_tail][0..n]);

    self.event_tail = (self.event_tail + 1) % EVENT_QUEUE_SIZE;
    self.event_count -= 1;
    return n;
}
