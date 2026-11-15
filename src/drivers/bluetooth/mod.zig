//! The Bluetooth stack: the protocol core and the transports.
//!
//! The pieces come from the Linux kernel:
//!
//!   * `hci.zig`   - the Host Controller Interface protocol core, from
//!     `net/bluetooth/hci_core.c` and `include/net/bluetooth/hci.h`.
//!   * `btusb.zig` - the USB transport, from `drivers/bluetooth/btusb.c`.
//!   * `vhci.zig`  - the virtual controller, from
//!     `drivers/bluetooth/hci_vhci.c`.
//!
//! Linux keeps the protocol core, the transports and the device models in
//! separate subsystems; here they are one small stack, because the kernel
//! has one use for it: to talk to a Bluetooth controller, whether it hangs
//! off a USB port or is provided by the hypervisor.

const serial = @import("../../system/serial.zig");
const hci = @import("hci.zig");
const btusb = @import("btusb.zig");
const vhci = @import("vhci.zig");

pub const Hci = hci;
pub const BdAddr = hci.BdAddr;
pub const Opcode = hci.Opcode;
pub const State = hci.State;
pub const Peer = hci.Peer;
pub const Controller = hci.Controller;

/// The virtual controller the kernel always has.
///
/// It is initialised with `.{}` and not with `undefined`: a global declared
/// `undefined` never gets the field defaults, and the controller's address
/// and flags live in those defaults.
pub var virtual_controller: vhci.Controller = .{};

/// True once `init()` has run.
pub var initialized: bool = false;

/// Bring the stack up.
///
/// A Bluetooth controller on a USB port is used when there is one; the
/// virtual controller is always available as well, because it is what the
/// hypervisor hands to a guest that wants a Bluetooth controller.
pub fn init() void {
    if (initialized) return;
    initialized = true;

    // The virtual controller first: it is always there, and it gives the
    // stack something to talk to even on a machine with no Bluetooth.
    if (virtual_controller.init()) {
        serial.serialWrite("[BT] Virtual controller ready, address ");
        var buf: [32]u8 = undefined;
        serial.serialWrite(hci.formatBdAddr(virtual_controller.core.addr, &buf));
        serial.serialWrite("\n");
    } else {
        serial.serialWrite("[BT] Virtual controller failed to initialise\n");
    }

    // A real controller, if the USB stack found one.
    if (btusb.probe()) {
        serial.serialWrite("[BT] USB controller bound\n");
    }
}

/// Read the pending events of every controller.
pub fn poll() void {
    if (!initialized) return;
    btusb.poll();
    virtual_controller.core.poll();
}

/// The number of controllers the stack knows about.
pub fn controllerCount() usize {
    return btusb.controllerCount() + 1;
}

/// The controller at `index`: the USB ones first, the virtual one last.
pub fn controller(index: usize) ?*Controller {
    if (index < btusb.controllerCount()) return btusb.controller(index);
    if (index == btusb.controllerCount()) return &virtual_controller.core;
    return null;
}

/// The name of a controller, for the shell output.
pub fn controllerName(index: usize) []const u8 {
    if (index < btusb.controllerCount()) return "usb";
    return "virtual";
}

/// Start an inquiry on one controller.
pub fn scan(index: usize) bool {
    const c = controller(index) orelse return false;
    if (!c.writeScanEnable(true)) return false;
    return c.inquiry(8, 8);
}
