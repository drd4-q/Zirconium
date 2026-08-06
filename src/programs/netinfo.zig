const root = @import("root");
const vga = root.vga;
const port = root.serial;
const pci = @import("../drivers/pci.zig");
const e1000 = @import("../drivers/e1000.zig");
const net = @import("../net/mod.zig");
const tcp = @import("../net/tcp.zig");
const arp_cache = @import("../net/arp_cache.zig");
const dhcp_mod = @import("../net/dhcp.zig");

pub fn run() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== Network Info ===\n\n");

    vga.setColor(.white, .black);
    vga.write("  MAC:      ");
    e1000.printMacVga();
    vga.write("\n");

    vga.write("  Our IP:   ");
    net.printIp(net.our_ip);
    if (dhcp_mod.lease_valid) {
        vga.setColor(.light_green, .black);
        vga.write(" (DHCP)");
    }
    vga.setColor(.white, .black);
    vga.write("\n");

    vga.write("  Gateway:  ");
    net.printIp(net.gateway_ip);
    vga.write("\n");

    vga.write("  GW MAC:   ");
    if (net.mac_known) {
        const h = "0123456789ABCDEF";
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            if (i > 0) vga.putChar(':');
            vga.putChar(h[net.gateway_mac[i] >> 4]);
            vga.putChar(h[net.gateway_mac[i] & 0xF]);
        }
    } else {
        vga.setColor(.light_red, .black);
        vga.write("(not resolved)");
    }
    vga.setColor(.white, .black);
    vga.write("\n\n");

    vga.setColor(.yellow, .black);
    vga.write("  TCP State: ");
    vga.setColor(.white, .black);
    switch (tcp.state) {
        .closed => vga.write("CLOSED"),
        .syn_sent => vga.write("SYN_SENT"),
        .established => vga.write("ESTABLISHED"),
        .fin_wait => vga.write("FIN_WAIT"),
    }
    vga.write("\n\n");

    // Show ARP cache
    arp_cache.printCache();
}
