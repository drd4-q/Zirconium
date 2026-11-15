//! The FTDI USB serial adapter.
//!
//! Ported from the Linux kernel's `drivers/usb/serial/ftdi_sio.c` and
//! `ftdi_sio.h`: the USB-to-serial bridges Future Technology Devices
//! (FTDI) makes, which are the most common USB serial adapters around.
//!
//! The chip speaks a small vendor protocol on top of USB:
//!
//!   * every USB packet the chip sends carries two status bytes in front
//!     of the data - the modem status and the line status;
//!   * the baud rate is a divisor of the chip's clock, not a number, and
//!     each chip family has its own formula;
//!   * the modem control lines (DTR, RTS) are bits in a vendor request.
//!
//! The vendor requests, from `ftdi_sio.h`:
//!
//!     0  reset the port
//!     1  set the modem control
//!     2  set the flow control
//!     3  set the baud rate
//!     4  set the data characteristics
//!     5  read the modem status
//!     9  set the USB latency timer

const serial = @import("../../../system/serial.zig");
const usb = @import("../mod.zig");
const usb_types = @import("../types.zig");
const device = @import("../device.zig");

const proto = @import("ftdi_proto.zig");

pub const VENDOR_ID = proto.VENDOR_ID;
pub const ProductId = proto.ProductId;
pub const ChipType = proto.ChipType;
pub const chipFor = proto.chipFor;
pub const Request = proto.Request;
pub const REQ_TYPE_OUT = proto.REQ_TYPE_OUT;
pub const REQ_TYPE_IN = proto.REQ_TYPE_IN;
pub const Reset = proto.Reset;
pub const ModemStatus = proto.ModemStatus;
pub const LineStatus = proto.LineStatus;
pub const ModemCtrl = proto.ModemCtrl;
pub const DataBits = proto.DataBits;
pub const divisor232am = proto.divisor232am;
pub const divisor2232h = proto.divisor2232h;

/// One FTDI port.
pub const Port = struct {
    /// The USB device the chip is on.
    dev: *device.UsbDevice = undefined,
    /// The chip family.
    chip: ChipType = .ft232r,
    /// The channel of a multi-port chip.
    channel: u8 = 0,
    /// The baud rate that is programmed into the chip.
    baud: u32 = 9600,
    /// The modem control lines the driver set.
    dtr: bool = false,
    rts: bool = false,
    /// The status bytes of the last packet.
    modem_status: u8 = 0,
    line_status: u8 = 0,
    /// How many bytes went out and came in.
    tx_bytes: u32 = 0,
    rx_bytes: u32 = 0,

    /// The baud rate divisor for the chip.
    pub fn divisor(self: Port, baud: u32) u32 {
        return switch (self.chip) {
            .ft2232h, .ft4232h, .ft232h => divisor2232h(baud),
            else => divisor232am(baud),
        };
    }

    /// Reset the port.
    pub fn reset(self: *Port) bool {
        const setup = usb_types.UsbSetupPacket{
            .bmRequestType = REQ_TYPE_OUT,
            .bRequest = Request.reset,
            .wValue = Reset.sio,
            .wIndex = self.channel,
            .wLength = 0,
        };
        const maxp0: u8 = @min(self.dev.ep0_max_packet, 64);
        return usb.usbControlTransferById(self.dev.id, maxp0, &setup, null, null);
    }

    /// Set the USB latency timer, so the chip does not sit on the bus.
    pub fn setLatencyTimer(self: *Port, latency_ms: u16) bool {
        const setup = usb_types.UsbSetupPacket{
            .bmRequestType = REQ_TYPE_OUT,
            .bRequest = Request.set_latency_timer,
            .wValue = latency_ms,
            .wIndex = 0,
            .wLength = 0,
        };
        const maxp0: u8 = @min(self.dev.ep0_max_packet, 64);
        return usb.usbControlTransferById(self.dev.id, maxp0, &setup, null, null);
    }

    /// Set the baud rate.
    pub fn setBaudRate(self: *Port, baud: u32) bool {
        const div = self.divisor(baud);
        const setup = usb_types.UsbSetupPacket{
            .bmRequestType = REQ_TYPE_OUT,
            .bRequest = Request.set_baudrate,
            .wValue = @truncate(div),
            .wIndex = @truncate(div >> 16),
            .wLength = 0,
        };
        const maxp0: u8 = @min(self.dev.ep0_max_packet, 64);
        if (!usb.usbControlTransferById(self.dev.id, maxp0, &setup, null, null)) return false;
        self.baud = baud;
        return true;
    }

    /// Set the data format: eight bits, one stop bit, no parity.
    pub fn setDataFormat(self: *Port) bool {
        const setup = usb_types.UsbSetupPacket{
            .bmRequestType = REQ_TYPE_OUT,
            .bRequest = Request.set_data,
            .wValue = 8 | DataBits.stop_bits_1 | DataBits.parity_none,
            .wIndex = 0,
            .wLength = 0,
        };
        const maxp0: u8 = @min(self.dev.ep0_max_packet, 64);
        return usb.usbControlTransferById(self.dev.id, maxp0, &setup, null, null);
    }

    /// Set the flow control: none.
    pub fn setFlowControl(self: *Port) bool {
        const setup = usb_types.UsbSetupPacket{
            .bmRequestType = REQ_TYPE_OUT,
            .bRequest = Request.flow_ctrl,
            .wValue = 0,
            .wIndex = 0,
            .wLength = 0,
        };
        const maxp0: u8 = @min(self.dev.ep0_max_packet, 64);
        return usb.usbControlTransferById(self.dev.id, maxp0, &setup, null, null);
    }

    /// Set the modem control lines.
    pub fn setModemCtrl(self: *Port, dtr: bool, rts: bool) bool {
        var value: u16 = 0;
        if (dtr) value |= ModemCtrl.dtr;
        if (rts) value |= ModemCtrl.rts;
        const setup = usb_types.UsbSetupPacket{
            .bmRequestType = REQ_TYPE_OUT,
            .bRequest = Request.modem_ctrl,
            .wValue = value,
            .wIndex = 0,
            .wLength = 0,
        };
        const maxp0: u8 = @min(self.dev.ep0_max_packet, 64);
        if (!usb.usbControlTransferById(self.dev.id, maxp0, &setup, null, null)) return false;
        self.dtr = dtr;
        self.rts = rts;
        return true;
    }

    /// Read the modem status.
    pub fn getModemStatus(self: *Port) bool {
        var buf: [2]u8 = @splat(0);
        const setup = usb_types.UsbSetupPacket{
            .bmRequestType = REQ_TYPE_IN,
            .bRequest = Request.get_modem_status,
            .wValue = 0,
            .wIndex = self.channel,
            .wLength = 2,
        };
        const maxp0: u8 = @min(self.dev.ep0_max_packet, 64);
        if (!usb.usbControlTransferById(self.dev.id, maxp0, &setup, null, &buf)) return false;
        self.modem_status = buf[0];
        self.line_status = buf[1];
        return true;
    }

    /// True when the chip says that the clear-to-send line is up.
    pub fn carrier(self: *const Port) bool {
        return (self.modem_status & ModemStatus.rlsd) != 0;
    }

    /// True when the chip says that the data set is ready.
    pub fn dataReady(self: *const Port) bool {
        return (self.modem_status & ModemStatus.dsr) != 0;
    }

    /// Write to the port.
    ///
    /// The data goes out on the bulk OUT endpoint; the chip takes it from
    /// there.
    pub fn write(self: *Port, data: []const u8) bool {
        if (data.len == 0) return true;
        if (self.dev.ep_bulk_out == 0) return false;
        if (!usb.usbBulkOutTransferById(self.dev.id, self.dev.ep_bulk_out, data)) return false;
        self.tx_bytes += @intCast(data.len);
        return true;
    }

    /// Read from the port.
    ///
    /// The chip prefixes every packet with the two status bytes, so they
    /// are taken off the front before the data is handed on.
    pub fn read(self: *Port, buf: []u8) ?usize {
        if (self.dev.ep_bulk_in == 0) return null;
        var packet: [512]u8 = @splat(0);
        const len = usb.usbBulkInTransferById(self.dev.id, self.dev.ep_bulk_in, &packet) orelse return null;
        if (len < 2) return 0;

        self.modem_status = packet[0];
        self.line_status = packet[1];

        const data_len = @min(len - 2, buf.len);
        @memcpy(buf[0..data_len], packet[2 .. 2 + data_len]);
        self.rx_bytes += @intCast(data_len);
        return data_len;
    }
};

pub const MAX_PORTS: usize = 4;

pub var ports: [MAX_PORTS]Port = undefined;
pub var port_count: usize = 0;

/// True when a chip has been found.
pub var initialized: bool = false;

/// Look for an FTDI chip and bring it up.
///
/// This is Linux's `ftdi_probe()` reduced to what the kernel needs: find
/// the device, reset the chip, program the line and let the caller talk to
/// it.
pub fn probe() bool {
    var i: usize = 0;
    while (i < usb.usb_device_count) : (i += 1) {
        const dev = &usb.usb_devices[i];
        if (!dev.active) continue;
        if (dev.vendor_id != VENDOR_ID) continue;

        const chip = chipFor(dev.product_id) orelse continue;
        if (port_count >= MAX_PORTS) break;

        var new_port = Port{};
        new_port.dev = dev;
        new_port.chip = chip;

        serial.serialWrite("[FTDI] Found ");
        serial.serialWrite(@tagName(chip));
        serial.serialWrite(" id=");
        serial.serialWriteDec(dev.id);
        serial.serialWrite(" bulk out=");
        serial.serialWriteDec(dev.ep_bulk_out);
        serial.serialWrite(" bulk in=");
        serial.serialWriteDec(dev.ep_bulk_in);
        serial.serialWrite("\n");

        // The order Linux uses: reset the port, then the latency timer,
        // then the line itself.
        if (!new_port.reset()) {
            serial.serialWrite("[FTDI] Reset failed\n");
            continue;
        }
        _ = new_port.setLatencyTimer(16);
        _ = new_port.setDataFormat();
        _ = new_port.setFlowControl();
        _ = new_port.setBaudRate(9600);
        _ = new_port.setModemCtrl(true, true);

        ports[port_count] = new_port;
        port_count += 1;
        initialized = true;
        return true;
    }
    return false;
}

/// Look for a chip that turned up after the enumeration.
///
/// The xHCI controller finds its devices while it is polled, so a chip
/// that is on an xHCI port is only visible after the first poll - which is
/// where this is called from.
pub fn poll() void {
    if (initialized) return;
    _ = probe();
}

/// The ports the driver found.
pub fn portCount() usize {
    return port_count;
}

/// The port at `index`.
pub fn port(index: usize) ?*Port {
    if (index >= port_count) return null;
    return &ports[index];
}

/// Write the state of the driver to the serial log.
pub fn printStatus(
    write: *const fn (s: []const u8) void,
    writeDec: *const fn (v: u64) void,
) void {
    if (port_count == 0) {
        write("  No FTDI adapters.\n");
        return;
    }
    var i: usize = 0;
    while (i < port_count) : (i += 1) {
        const p = &ports[i];
        write("  FTDI adapter ");
        writeDec(i);
        write("\n    chip      : ");
        write(@tagName(p.chip));
        write("\n    baud      : ");
        writeDec(p.baud);
        write("\n    modem     : ");
        writeDec(p.modem_status);
        write("\n    line      : ");
        writeDec(p.line_status);
        write("\n    carrier   : ");
        write(if (p.carrier()) "yes" else "no");
        write("\n    tx / rx   : ");
        writeDec(p.tx_bytes);
        write(" / ");
        writeDec(p.rx_bytes);
        write("\n");
    }
}
