const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const pci = @import("pci.zig");
const blockdev = @import("../fs/blockdev.zig");

// Global HBA registers (ABAR)
const HOST_CAP: u32 = 0x00;
const HOST_CTL: u32 = 0x04;
const HOST_IRQ_STAT: u32 = 0x08;
const HOST_PORTS_IMPL: u32 = 0x0C;
const HOST_VERSION: u32 = 0x10;

const HOST_CTL_AHCI_EN: u32 = 1 << 31;
const HOST_CTL_RESET: u32 = 1 << 0;

// Port registers
const PORT_CLB: u32 = 0x00;
const PORT_CLBU: u32 = 0x04;
const PORT_FB: u32 = 0x08;
const PORT_FBU: u32 = 0x0C;
const PORT_IS: u32 = 0x10;
const PORT_IE: u32 = 0x14;
const PORT_CMD: u32 = 0x18;
const PORT_TFD: u32 = 0x20;
const PORT_SIG: u32 = 0x24;
const PORT_SSTS: u32 = 0x28;
const PORT_SCTL: u32 = 0x2C;
const PORT_SERR: u32 = 0x30;
const PORT_SACT: u32 = 0x34;
const PORT_CI: u32 = 0x38;

const PORT_CMD_ST: u32 = 1 << 0;
const PORT_CMD_FRE: u32 = 1 << 4;
const PORT_CMD_FR: u32 = 1 << 14;
const PORT_CMD_CR: u32 = 1 << 15;

const SATA_SIG_ATA: u32 = 0x00000101;
const ATA_DEV_BUSY: u8 = 0x80;
const ATA_DEV_DRQ: u8 = 0x08;

const ATA_CMD_READ_DMA_EXT: u8 = 0x25;
const ATA_CMD_WRITE_DMA_EXT: u8 = 0x35;
const ATA_CMD_IDENTIFY: u8 = 0xEC;

const FIS_TYPE_REG_H2D: u8 = 0x27;

const MAX_AHCI_PORTS: usize = 4;

// 32-byte Command Header
const HbaCmdHeader = extern struct {
    flags: u16,
    prdtl: u16,
    prdbc: u32,
    ctba: u32,
    ctbau: u32,
    reserved: [4]u32,
};

// 16-byte PRD Entry
const HbaPrdtEntry = extern struct {
    dba: u32,
    dbau: u32,
    reserved: u32,
    dbc: u32, // Bit 31: Interrupt on completion, Bits 21:0 byte count (0-based)
};

// Command Table
const HbaCmdTable = extern struct {
    cfis: [64]u8,
    acmd: [16]u8,
    reserved: [48]u8,
    prdt_entry: [1]HbaPrdtEntry,
};

var cmd_headers: [MAX_AHCI_PORTS][32]HbaCmdHeader align(1024) = undefined;
var received_fis: [MAX_AHCI_PORTS][256]u8 align(256) = undefined;
var cmd_tables: [MAX_AHCI_PORTS]HbaCmdTable align(128) = undefined;

var dma_buffer: [8192]u8 align(4096) = undefined;

pub const AhciDrive = struct {
    port_no: u32,
    sector_count: u64,
    block_dev: blockdev.BlockDevice,
};

pub var drives: [MAX_AHCI_PORTS]AhciDrive = undefined;
pub var drive_count: usize = 0;
var abar: u64 = 0;

fn readReg(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(abar + @as(u64, offset));
    return ptr.*;
}

fn writeReg(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(abar + @as(u64, offset));
    ptr.* = val;
}

fn portBase(port_no: u32) u32 {
    return 0x100 + port_no * 0x80;
}

fn portRead(port_no: u32, offset: u32) u32 {
    return readReg(portBase(port_no) + offset);
}

fn portWrite(port_no: u32, offset: u32, val: u32) void {
    writeReg(portBase(port_no) + offset, val);
}

fn stopPort(port_no: u32) void {
    var cmd = portRead(port_no, PORT_CMD);
    cmd &= ~PORT_CMD_ST;
    cmd &= ~PORT_CMD_FRE;
    portWrite(port_no, PORT_CMD, cmd);

    var timeout: u32 = 0;
    while ((portRead(port_no, PORT_CMD) & (PORT_CMD_FR | PORT_CMD_CR)) != 0 and timeout < 100_000) : (timeout += 1) {
        asm volatile ("pause");
    }
}

fn startPort(port_no: u32) void {
    while ((portRead(port_no, PORT_CMD) & PORT_CMD_CR) != 0) {
        asm volatile ("pause");
    }
    var cmd = portRead(port_no, PORT_CMD);
    cmd |= PORT_CMD_FRE;
    cmd |= PORT_CMD_ST;
    portWrite(port_no, PORT_CMD, cmd);
}

pub fn init() bool {
    pci.scan();
    var ahci_dev: ?*pci.PciDevice = null;
    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const d = &pci.devices[i];
        if (d.class == 0x01 and d.subclass == 0x06) {
            ahci_dev = d;
            break;
        }
    }

    const dev = ahci_dev orelse {
        port.serialWrite("[AHCI] No AHCI controller found\n");
        return false;
    };

    port.serialWrite("[AHCI] Found SATA AHCI controller on PCI ");
    port.serialWriteDec(dev.bus);
    port.serialWrite(":");
    port.serialWriteDec(dev.dev);
    port.serialWrite("\n");

    pci.enableBusMaster(dev.bus, dev.dev, dev.func);

    const bar5 = pci.readBar(dev.bus, dev.dev, dev.func, 5);
    if (bar5 == 0 or (bar5 & 1) != 0) {
        port.serialWrite("[AHCI] Error: invalid ABAR (BAR5)\n");
        return false;
    }

    abar = @as(u64, bar5 & 0xFFFFFFF0);
    port.serialWrite("[AHCI] ABAR base: 0x");
    port.serialWriteHex(abar);
    port.serialWrite("\n");

    // Enable AHCI Mode
    writeReg(HOST_CTL, readReg(HOST_CTL) | HOST_CTL_AHCI_EN);

    const pi = readReg(HOST_PORTS_IMPL);
    port.serialWrite("[AHCI] Implemented ports bitmap: 0x");
    port.serialWriteHex(pi);
    port.serialWrite("\n");

    drive_count = 0;
    var p: u32 = 0;
    while (p < 32 and drive_count < MAX_AHCI_PORTS) : (p += 1) {
        if ((pi & (@as(u32, 1) << @intCast(p))) != 0) {
            probePort(p);
        }
    }

    port.serialWrite("[AHCI] Detected ");
    port.serialWriteDec(drive_count);
    port.serialWrite(" SATA drive(s)\n");

    return drive_count > 0;
}

fn probePort(port_no: u32) void {
    const ssts = portRead(port_no, PORT_SSTS);
    const ipm = (ssts >> 8) & 0x0F;
    const det = ssts & 0x0F;

    if (det != 3 or ipm != 1) {
        return; // Device not present or not active
    }

    const sig = portRead(port_no, PORT_SIG);
    if (sig != SATA_SIG_ATA) {
        return; // Not standard SATA hard drive (e.g. ATAPI CD-ROM)
    }

    port.serialWrite("[AHCI] Port ");
    port.serialWriteDec(port_no);
    port.serialWrite(": SATA drive detected, initializing...\n");

    stopPort(port_no);

    const clb_phys = @intFromPtr(&cmd_headers[drive_count]);
    const fb_phys = @intFromPtr(&received_fis[drive_count]);
    const ctba_phys = @intFromPtr(&cmd_tables[drive_count]);

    @memset(@as([*]u8, @ptrCast(&cmd_headers[drive_count]))[0..@sizeOf(@TypeOf(cmd_headers[0]))], 0);
    @memset(@as([*]u8, @ptrCast(&received_fis[drive_count]))[0..256], 0);
    @memset(@as([*]u8, @ptrCast(&cmd_tables[drive_count]))[0..@sizeOf(HbaCmdTable)], 0);

    portWrite(port_no, PORT_CLB, @intCast(clb_phys & 0xFFFFFFFF));
    portWrite(port_no, PORT_CLBU, @intCast((clb_phys >> 32) & 0xFFFFFFFF));
    portWrite(port_no, PORT_FB, @intCast(fb_phys & 0xFFFFFFFF));
    portWrite(port_no, PORT_FBU, @intCast((fb_phys >> 32) & 0xFFFFFFFF));

    // Setup command header 0 to point to command table
    cmd_headers[drive_count][0].ctba = @intCast(ctba_phys & 0xFFFFFFFF);
    cmd_headers[drive_count][0].ctbau = @intCast((ctba_phys >> 32) & 0xFFFFFFFF);
    cmd_headers[drive_count][0].prdtl = 1;

    // Clear error & interrupt status
    portWrite(port_no, PORT_SERR, 0xFFFFFFFF);
    portWrite(port_no, PORT_IS, 0xFFFFFFFF);

    startPort(port_no);

    // Identify drive to get sector count
    const sectors = identifyDrive(port_no, drive_count);

    const d = &drives[drive_count];
    d.port_no = port_no;
    d.sector_count = if (sectors > 0) sectors else 2097152; // Fallback 1GB

    @memset(d.block_dev.name[0..], 0);
    const prefix = "ahci";
    @memcpy(d.block_dev.name[0..prefix.len], prefix);
    d.block_dev.name[prefix.len] = @intCast('0' + drive_count);
    d.block_dev.sector_size = 512;
    d.block_dev.readFn = readSectorWrapper;
    d.block_dev.writeFn = writeSectorWrapper;
    d.block_dev.totalSectorsFn = totalSectorsWrapper;

    blockdev.register(&d.block_dev);

    port.serialWrite("[AHCI] Drive registered as ");
    port.serialWrite(d.block_dev.name[0 .. prefix.len + 1]);
    port.serialWrite(" (");
    port.serialWriteDec(d.sector_count * 512 / (1024 * 1024));
    port.serialWrite(" MB)\n");

    drive_count += 1;
}

fn identifyDrive(port_no: u32, slot_idx: usize) u64 {
    const ct = &cmd_tables[slot_idx];
    @memset(ct.cfis[0..], 0);
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // Command bit
    ct.cfis[2] = ATA_CMD_IDENTIFY;

    ct.prdt_entry[0].dba = @intCast(@intFromPtr(&dma_buffer) & 0xFFFFFFFF);
    ct.prdt_entry[0].dbau = @intCast((@intFromPtr(&dma_buffer) >> 32) & 0xFFFFFFFF);
    ct.prdt_entry[0].dbc = (512 - 1) | (1 << 31);

    cmd_headers[slot_idx][0].flags = 5; // 5 DWORDS in FIS
    cmd_headers[slot_idx][0].prdtl = 1;

    portWrite(port_no, PORT_CI, 1);

    var spins: u32 = 0;
    while ((portRead(port_no, PORT_CI) & 1) != 0 and spins < 500_000) : (spins += 1) {
        asm volatile ("pause");
    }

    if ((portRead(port_no, PORT_CI) & 1) == 0) {
        // Words 100-103 contain 48-bit total sectors
        const ptr16: [*]const u16 = @ptrCast(&dma_buffer);
        const lba48: u64 = @as(u64, ptr16[100]) |
            (@as(u64, ptr16[101]) << 16) |
            (@as(u64, ptr16[102]) << 32) |
            (@as(u64, ptr16[103]) << 48);
        if (lba48 > 0) return lba48;
    }
    return 0;
}

pub fn readSector(port_no: u32, slot_idx: usize, lba: u64, buf: []u8) bool {
    if (buf.len < 512) return false;

    // Wait until port is not busy
    var spins: u32 = 0;
    while ((portRead(port_no, PORT_TFD) & (ATA_DEV_BUSY | ATA_DEV_DRQ)) != 0 and spins < 100_000) : (spins += 1) {
        asm volatile ("pause");
    }

    const ct = &cmd_tables[slot_idx];
    @memset(ct.cfis[0..], 0);
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80; // Command bit
    ct.cfis[2] = ATA_CMD_READ_DMA_EXT;

    ct.cfis[4] = @intCast(lba & 0xFF);
    ct.cfis[5] = @intCast((lba >> 8) & 0xFF);
    ct.cfis[6] = @intCast((lba >> 16) & 0xFF);
    ct.cfis[7] = 0x40; // LBA mode

    ct.cfis[8] = @intCast((lba >> 24) & 0xFF);
    ct.cfis[9] = @intCast((lba >> 32) & 0xFF);
    ct.cfis[10] = @intCast((lba >> 40) & 0xFF);

    ct.cfis[12] = 1; // Sector count low
    ct.cfis[13] = 0; // Sector count high

    ct.prdt_entry[0].dba = @intCast(@intFromPtr(&dma_buffer) & 0xFFFFFFFF);
    ct.prdt_entry[0].dbau = @intCast((@intFromPtr(&dma_buffer) >> 32) & 0xFFFFFFFF);
    ct.prdt_entry[0].dbc = (512 - 1) | (1 << 31);

    cmd_headers[slot_idx][0].flags = 5; // 5 DWORDS, read
    cmd_headers[slot_idx][0].prdtl = 1;

    portWrite(port_no, PORT_IS, 0xFFFFFFFF);
    portWrite(port_no, PORT_CI, 1);

    spins = 0;
    while ((portRead(port_no, PORT_CI) & 1) != 0 and spins < 500_000) : (spins += 1) {
        asm volatile ("pause");
    }

    if ((portRead(port_no, PORT_IS) & (1 << 30)) != 0) { // Taskfile error
        return false;
    }

    if ((portRead(port_no, PORT_CI) & 1) == 0) {
        @memcpy(buf[0..512], dma_buffer[0..512]);
        return true;
    }
    return false;
}

pub fn writeSector(port_no: u32, slot_idx: usize, lba: u64, buf: []const u8) bool {
    if (buf.len < 512) return false;

    var spins: u32 = 0;
    while ((portRead(port_no, PORT_TFD) & (ATA_DEV_BUSY | ATA_DEV_DRQ)) != 0 and spins < 100_000) : (spins += 1) {
        asm volatile ("pause");
    }

    @memcpy(dma_buffer[0..512], buf[0..512]);

    const ct = &cmd_tables[slot_idx];
    @memset(ct.cfis[0..], 0);
    ct.cfis[0] = FIS_TYPE_REG_H2D;
    ct.cfis[1] = 0x80;
    ct.cfis[2] = ATA_CMD_WRITE_DMA_EXT;

    ct.cfis[4] = @intCast(lba & 0xFF);
    ct.cfis[5] = @intCast((lba >> 8) & 0xFF);
    ct.cfis[6] = @intCast((lba >> 16) & 0xFF);
    ct.cfis[7] = 0x40;

    ct.cfis[8] = @intCast((lba >> 24) & 0xFF);
    ct.cfis[9] = @intCast((lba >> 32) & 0xFF);
    ct.cfis[10] = @intCast((lba >> 40) & 0xFF);

    ct.cfis[12] = 1;
    ct.cfis[13] = 0;

    ct.prdt_entry[0].dba = @intCast(@intFromPtr(&dma_buffer) & 0xFFFFFFFF);
    ct.prdt_entry[0].dbau = @intCast((@intFromPtr(&dma_buffer) >> 32) & 0xFFFFFFFF);
    ct.prdt_entry[0].dbc = (512 - 1) | (1 << 31);

    cmd_headers[slot_idx][0].flags = 5 | (1 << 6); // 5 DWORDS, write bit (bit 6)
    cmd_headers[slot_idx][0].prdtl = 1;

    portWrite(port_no, PORT_IS, 0xFFFFFFFF);
    portWrite(port_no, PORT_CI, 1);

    spins = 0;
    while ((portRead(port_no, PORT_CI) & 1) != 0 and spins < 500_000) : (spins += 1) {
        asm volatile ("pause");
    }

    if ((portRead(port_no, PORT_IS) & (1 << 30)) != 0) {
        return false;
    }

    return (portRead(port_no, PORT_CI) & 1) == 0;
}

fn getDriveFromDev(dev: *blockdev.BlockDevice) ?*AhciDrive {
    var i: usize = 0;
    while (i < drive_count) : (i += 1) {
        if (&drives[i].block_dev == dev) return &drives[i];
    }
    return null;
}

fn readSectorWrapper(dev: *blockdev.BlockDevice, sector: u64, buf: []u8) bool {
    const d = getDriveFromDev(dev) orelse return false;
    return readSector(d.port_no, @intCast(d.port_no), sector, buf);
}

fn writeSectorWrapper(dev: *blockdev.BlockDevice, sector: u64, buf: []const u8) bool {
    const d = getDriveFromDev(dev) orelse return false;
    return writeSector(d.port_no, @intCast(d.port_no), sector, buf);
}

fn totalSectorsWrapper(dev: *blockdev.BlockDevice) u64 {
    const d = getDriveFromDev(dev) orelse return 0;
    return d.sector_count;
}
