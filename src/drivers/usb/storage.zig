/// USB Mass Storage Class (BOT / SCSI) Driver for Zirconium OS
/// Implements USB Mass Storage Bulk-Only Transport (USB MSC BOT) and SCSI
/// Transparent Command Set (RFC/Specification USB Mass Storage Class Bulk-Only Transport 1.0)
/// Ported and adapted from Linux kernel (drivers/usb/storage/transport.c, protocol.c, scsiglue.c)
const std = @import("std");
const root = @import("root");
const serial = root.serial;
const timer = @import("../timer.zig");
const blockdev = @import("../../fs/blockdev.zig");
const partition = @import("../../fs/partition.zig");
const types = @import("types.zig");
const device = @import("device.zig");
const mod = @import("mod.zig");

pub const MAX_STORAGE_DRIVES: usize = 4;

pub const UsbStorageDrive = struct {
    dev: *device.UsbDevice,
    lun: u8 = 0,
    total_sectors: u64 = 0,
    sector_size: usize = 512,
    vendor: [9]u8 = [_]u8{0} ** 9,
    product: [17]u8 = [_]u8{0} ** 17,
    revision: [5]u8 = [_]u8{0} ** 5,
    tag_counter: u32 = 1,
    initialized: bool = false,
    block_dev: blockdev.BlockDevice = undefined,

    fn nextTag(self: *UsbStorageDrive) u32 {
        self.tag_counter +%= 1;
        if (self.tag_counter == 0) self.tag_counter = 1;
        return self.tag_counter;
    }
};

pub var storage_drives: [MAX_STORAGE_DRIVES]UsbStorageDrive = undefined;
pub var storage_drive_count: usize = 0;

fn spinDelayMs(ms: u32) void {
    if (timer.ticks > 0) {
        const needed: u64 = if (ms == 0) 0 else ((@as(u64, ms) + 9) / 10);
        const target = timer.ticks + needed;
        while (timer.ticks < target) {
            asm volatile ("pause");
        }
    } else {
        var i: u32 = 0;
        while (i < ms * 10000) : (i += 1) {
            asm volatile ("pause");
        }
    }
}

// ─── USB Bulk-Only Transport (BOT) Core ─────────────────────────────────────

/// Reset Recovery procedure (BOT Spec §5.3.4 and Linux usb_stor_reset)
pub fn botResetRecovery(sdev: *UsbStorageDrive) bool {
    const dev = sdev.dev;

    // 1. Bulk-Only Mass Storage Reset (Control transfer to EP0)
    const reset_pkt = types.UsbSetupPacket{
        .bmRequestType = 0x21, // Class, Interface, Host-to-Device
        .bRequest = types.US_BULK_RESET_REQUEST,
        .wValue = 0,
        .wIndex = dev.interface_num,
        .wLength = 0,
    };
    const maxp0: u8 = @intCast(@min(dev.ep_max_packet, 64));
    _ = mod.usbControlTransfer(dev.addr, maxp0, &reset_pkt, null, null);
    spinDelayMs(10);

    // 2. Clear Feature ENDPOINT_HALT on Bulk-In endpoint
    if (dev.ep_bulk_in != 0) {
        _ = mod.usbClearHalt(dev, dev.ep_bulk_in, true);
        dev.ep_bulk_in_toggle = 0;
    }

    // 3. Clear Feature ENDPOINT_HALT on Bulk-Out endpoint
    if (dev.ep_bulk_out != 0) {
        _ = mod.usbClearHalt(dev, dev.ep_bulk_out, false);
        dev.ep_bulk_out_toggle = 0;
    }

    spinDelayMs(10);
    return true;
}

/// Execute a SCSI command wrapped in a USB BOT transaction
fn botExecute(
    sdev: *UsbStorageDrive,
    cdb: []const u8,
    is_in: bool,
    data: ?[]u8,
) bool {
    const dev = sdev.dev;
    if (dev.ep_bulk_out == 0 or dev.ep_bulk_in == 0) return false;

    const data_len: u32 = if (data) |d| @intCast(d.len) else 0;
    const tag = sdev.nextTag();

    // ─── Stage 1: Command Transport (Host -> Device via Bulk OUT) ─────────
    var cbw = types.UsbCbw{
        .dCBWSignature = 0x43425355, // "USBC"
        .dCBWTag = tag,
        .dCBWDataTransferLength = data_len,
        .bmCBWFlags = if (is_in and data_len > 0) 0x80 else 0x00,
        .bCBWLUN = sdev.lun,
        .bCBWCBLength = @intCast(@min(cdb.len, 16)),
    };
    @memcpy(cbw.CBWCB[0..cbw.bCBWCBLength], cdb[0..cbw.bCBWCBLength]);

    const cbw_slice: [*]u8 = @ptrCast(&cbw);
    const cbw_bytes = cbw_slice[0..31];
    const sent_cbw = mod.usbBulkTransfer(dev, dev.ep_bulk_out, false, cbw_bytes);
    if (sent_cbw == null or sent_cbw.? != 31) {
        serial.serialWrite("[USB-STORAGE] Failed to send CBW\n");
        _ = botResetRecovery(sdev);
        return false;
    }

    // ─── Stage 2: Data Transport (Optional) ──────────────────────────────
    if (data) |d| {
        if (d.len > 0) {
            if (is_in) {
                const recvd = mod.usbBulkTransfer(dev, dev.ep_bulk_in, true, d);
                if (recvd == null) {
                    _ = mod.usbClearHalt(dev, dev.ep_bulk_in, true);
                    dev.ep_bulk_in_toggle = 0;
                }
            } else {
                const sent = mod.usbBulkTransfer(dev, dev.ep_bulk_out, false, d);
                if (sent == null) {
                    _ = mod.usbClearHalt(dev, dev.ep_bulk_out, false);
                    dev.ep_bulk_out_toggle = 0;
                }
            }
        }
    }

    // ─── Stage 3: Status Transport (Device -> Host via Bulk IN) ──────────
    var csw = types.UsbCsw{
        .dCSWSignature = 0,
        .dCSWTag = 0,
        .dCSWDataResidue = 0,
        .bCSWStatus = 0xFF,
    };
    const csw_slice: [*]u8 = @ptrCast(&csw);
    const csw_bytes = csw_slice[0..13];

    var csw_recvd = mod.usbBulkTransfer(dev, dev.ep_bulk_in, true, csw_bytes);
    if (csw_recvd == null or csw_recvd.? != 13) {
        // Try clearing halt and retry reading CSW once (per BOT specification)
        _ = mod.usbClearHalt(dev, dev.ep_bulk_in, true);
        dev.ep_bulk_in_toggle = 0;
        csw_recvd = mod.usbBulkTransfer(dev, dev.ep_bulk_in, true, csw_bytes);
        if (csw_recvd == null or csw_recvd.? != 13) {
            serial.serialWrite("[USB-STORAGE] Failed to receive valid CSW\n");
            _ = botResetRecovery(sdev);
            return false;
        }
    }

    // Validate CSW Signature ("USBS" = 0x53425355) and Tag
    if (csw.dCSWSignature != 0x53425355 or csw.dCSWTag != tag) {
        serial.serialWrite("[USB-STORAGE] CSW signature or tag mismatch\n");
        _ = botResetRecovery(sdev);
        return false;
    }

    // Status: 0 = Good / Passed, 1 = Failed, 2 = Phase Error
    if (csw.bCSWStatus == 0) {
        return true;
    } else if (csw.bCSWStatus == 1) {
        return false;
    } else {
        _ = botResetRecovery(sdev);
        return false;
    }
}

// ─── SCSI Commands ──────────────────────────────────────────────────────────

/// SCSI INQUIRY (0x12) - Get device identification strings
pub fn scsiInquiry(sdev: *UsbStorageDrive) bool {
    var inq_buf: [36]u8 = [_]u8{0} ** 36;
    const cdb = [_]u8{ types.SCSI_INQUIRY, 0, 0, 0, 36, 0 };

    if (!botExecute(sdev, &cdb, true, &inq_buf)) {
        return false;
    }

    // Bytes 8..15: Vendor ID (8 ASCII bytes)
    for (0..8) |i| {
        const ch = inq_buf[8 + i];
        sdev.vendor[i] = if (ch >= 32 and ch <= 126) ch else ' ';
    }
    sdev.vendor[8] = 0;

    // Bytes 16..31: Product ID (16 ASCII bytes)
    for (0..16) |i| {
        const ch = inq_buf[16 + i];
        sdev.product[i] = if (ch >= 32 and ch <= 126) ch else ' ';
    }
    sdev.product[16] = 0;

    // Bytes 32..35: Product Revision (4 ASCII bytes)
    for (0..4) |i| {
        const ch = inq_buf[32 + i];
        sdev.revision[i] = if (ch >= 32 and ch <= 126) ch else ' ';
    }
    sdev.revision[4] = 0;

    return true;
}

/// SCSI REQUEST SENSE (0x03) - Read sense data after command failure
pub fn scsiRequestSense(sdev: *UsbStorageDrive, sense_out: ?*([18]u8)) bool {
    var sense_buf: [18]u8 = [_]u8{0} ** 18;
    const cdb = [_]u8{ types.SCSI_REQUEST_SENSE, 0, 0, 0, 18, 0 };

    if (botExecute(sdev, &cdb, true, &sense_buf)) {
        if (sense_out) |so| {
            @memcpy(so, &sense_buf);
        }
        return true;
    }
    return false;
}

/// SCSI TEST UNIT READY (0x00) - Poll until ready (with retries like Linux)
pub fn scsiTestUnitReady(sdev: *UsbStorageDrive) bool {
    const cdb = [_]u8{ types.SCSI_TEST_UNIT_READY, 0, 0, 0, 0, 0 };
    var retries: usize = 0;

    while (retries < 6) : (retries += 1) {
        if (botExecute(sdev, &cdb, false, null)) {
            return true;
        }
        _ = scsiRequestSense(sdev, null);
        spinDelayMs(20);
    }
    return false;
}

/// SCSI READ CAPACITY (10) (0x25) - Obtain total LBA count and block size
pub fn scsiReadCapacity(sdev: *UsbStorageDrive) bool {
    var cap_buf: [8]u8 = [_]u8{0} ** 8;
    const cdb = [_]u8{ types.SCSI_READ_CAPACITY_10, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    if (!botExecute(sdev, &cdb, true, &cap_buf)) {
        return false;
    }

    const last_lba: u64 = (@as(u64, cap_buf[0]) << 24) |
        (@as(u64, cap_buf[1]) << 16) |
        (@as(u64, cap_buf[2]) << 8) |
        @as(u64, cap_buf[3]);

    const block_len: u32 = (@as(u32, cap_buf[4]) << 24) |
        (@as(u32, cap_buf[5]) << 16) |
        (@as(u32, cap_buf[6]) << 8) |
        @as(u32, cap_buf[7]);

    sdev.total_sectors = last_lba + 1;
    sdev.sector_size = if (block_len >= 512 and block_len <= 4096) block_len else 512;

    return true;
}

/// SCSI READ (10) (0x28) - Read sectors into memory
pub fn scsiRead10(sdev: *UsbStorageDrive, lba: u64, count: u16, buf: []u8) bool {
    if (count == 0) return true;
    const needed = @as(usize, count) * sdev.sector_size;
    if (buf.len < needed) return false;

    const cdb = [_]u8{
        types.SCSI_READ_10,
        0,
        @intCast((lba >> 24) & 0xFF),
        @intCast((lba >> 16) & 0xFF),
        @intCast((lba >> 8) & 0xFF),
        @intCast(lba & 0xFF),
        0,
        @intCast((count >> 8) & 0xFF),
        @intCast(count & 0xFF),
        0,
    };

    return botExecute(sdev, &cdb, true, buf[0..needed]);
}

/// SCSI WRITE (10) (0x2A) - Write sectors to disk
pub fn scsiWrite10(sdev: *UsbStorageDrive, lba: u64, count: u16, buf: []const u8) bool {
    if (count == 0) return true;
    const needed = @as(usize, count) * sdev.sector_size;
    if (buf.len < needed) return false;

    const cdb = [_]u8{
        types.SCSI_WRITE_10,
        0,
        @intCast((lba >> 24) & 0xFF),
        @intCast((lba >> 16) & 0xFF),
        @intCast((lba >> 8) & 0xFF),
        @intCast(lba & 0xFF),
        0,
        @intCast((count >> 8) & 0xFF),
        @intCast(count & 0xFF),
        0,
    };

    // Cast const slice to mut slice for transport API (BOT OUT transfer will not modify it)
    const mut_buf: []u8 = @constCast(buf[0..needed]);
    return botExecute(sdev, &cdb, false, mut_buf);
}

// ─── Block Device Abstraction Callbacks ─────────────────────────────────────

fn getDriveFromBlockDev(dev: *blockdev.BlockDevice) ?*UsbStorageDrive {
    var i: usize = 0;
    while (i < storage_drive_count) : (i += 1) {
        if (&storage_drives[i].block_dev == dev) {
            return &storage_drives[i];
        }
    }
    return null;
}

fn blockReadWrapper(dev: *blockdev.BlockDevice, sector: u64, buf: []u8) bool {
    const sdev = getDriveFromBlockDev(dev) orelse return false;
    return scsiRead10(sdev, sector, 1, buf);
}

fn blockWriteWrapper(dev: *blockdev.BlockDevice, sector: u64, buf: []const u8) bool {
    const sdev = getDriveFromBlockDev(dev) orelse return false;
    return scsiWrite10(sdev, sector, 1, buf);
}

fn blockTotalSectorsWrapper(dev: *blockdev.BlockDevice) u64 {
    const sdev = getDriveFromBlockDev(dev) orelse return 0;
    return sdev.total_sectors;
}

// ─── Driver Lifecycle & Registration ────────────────────────────────────────

pub fn initDrive(dev: *device.UsbDevice) bool {
    if (storage_drive_count >= MAX_STORAGE_DRIVES) return false;

    var sdev = &storage_drives[storage_drive_count];
    sdev.dev = dev;
    sdev.lun = 0;
    sdev.tag_counter = 1;
    sdev.total_sectors = 0;
    sdev.sector_size = 512;
    sdev.initialized = false;

    // 1. Check/Fetch Max LUN via Class Control Request (optional per spec)
    const get_max_lun_pkt = types.UsbSetupPacket{
        .bmRequestType = 0xA1, // Class, Interface, Device-to-Host
        .bRequest = types.US_BULK_GET_MAX_LUN,
        .wValue = 0,
        .wIndex = dev.interface_num,
        .wLength = 1,
    };
    var max_lun_buf: [1]u8 = [_]u8{0};
    const maxp0: u8 = @intCast(@min(dev.ep_max_packet, 64));
    if (mod.usbControlTransfer(dev.addr, maxp0, &get_max_lun_pkt, null, &max_lun_buf)) {
        sdev.lun = max_lun_buf[0] & 0x0F; // Primary LUN
    } else {
        // Some single-LUN devices stall this request per spec; clear halt and continue
        _ = mod.usbClearHalt(dev, 0, false);
        sdev.lun = 0;
    }

    // 2. Identify drive with SCSI INQUIRY
    if (!scsiInquiry(sdev)) {
        serial.serialWrite("[USB-STORAGE] Warning: SCSI INQUIRY failed, retrying...\n");
        _ = botResetRecovery(sdev);
        if (!scsiInquiry(sdev)) {
            serial.serialWrite("[USB-STORAGE] Drive did not respond to INQUIRY\n");
            return false;
        }
    }

    // 3. Test Unit Ready
    _ = scsiTestUnitReady(sdev);

    // 4. Read Capacity
    if (!scsiReadCapacity(sdev)) {
        serial.serialWrite("[USB-STORAGE] Failed to read capacity\n");
        return false;
    }

    // 5. Populate and register BlockDevice
    var name_buf: [32]u8 = [_]u8{0} ** 32;
    const base_name = "usb-disk";
    @memcpy(name_buf[0..base_name.len], base_name);
    name_buf[base_name.len] = @as(u8, @intCast(storage_drive_count)) + '0';

    sdev.block_dev = blockdev.BlockDevice{
        .readFn = blockReadWrapper,
        .writeFn = blockWriteWrapper,
        .totalSectorsFn = blockTotalSectorsWrapper,
        .name = name_buf,
        .sector_size = sdev.sector_size,
    };

    blockdev.register(&sdev.block_dev);
    sdev.initialized = true;
    storage_drive_count += 1;

    // Serial & console announcement
    const size_mb = (sdev.total_sectors * sdev.sector_size) / (1024 * 1024);
    serial.serialWrite("[USB-STORAGE] Initialized USB Drive: ");
    serial.serialWrite(&sdev.vendor);
    serial.serialWrite(" ");
    serial.serialWrite(&sdev.product);
    serial.serialWrite(" (");
    serial.serialWriteDec(sdev.total_sectors);
    serial.serialWrite(" sectors, ");
    serial.serialWriteDec(size_mb);
    serial.serialWrite(" MB, sector size ");
    serial.serialWriteDec(sdev.sector_size);
    serial.serialWrite(" bytes)\n");

    // Scan MBR / GPT partitions on this new block device
    partition.scanDevice(&sdev.block_dev);

    return true;
}

/// Scan all connected USB devices and attach USB Mass Storage drives
pub fn init() usize {
    var initialized_count: usize = 0;
    var i: usize = 0;
    while (i < mod.usb_device_count) : (i += 1) {
        const dev = &mod.usb_devices[i];
        if (!dev.active) continue;

        // Check if device is Mass Storage
        var is_storage = (dev.dev_type == .storage);
        if (!is_storage) {
            var if_idx: usize = 0;
            while (if_idx < dev.interface_count) : (if_idx += 1) {
                if (dev.interfaces[if_idx].class_code == @intFromEnum(types.UsbDeviceClass.mass_storage)) {
                    is_storage = true;
                    break;
                }
            }
        }

        if (is_storage and dev.ep_bulk_in != 0 and dev.ep_bulk_out != 0) {
            if (initDrive(dev)) {
                initialized_count += 1;
            }
        }
    }
    return initialized_count;
}

pub fn printStatus(
    writeFn: *const fn (s: []const u8) void,
    writeDecFn: *const fn (v: u64) void,
    writeHexFn: *const fn (v: u64) void,
) void {
    _ = writeHexFn;
    writeFn("=== USB Mass Storage Subsystem ===\n\n");
    if (storage_drive_count == 0) {
        writeFn("  No active USB mass storage drives attached.\n\n");
        return;
    }

    var i: usize = 0;
    while (i < storage_drive_count) : (i += 1) {
        const d = &storage_drives[i];
        writeFn("  Drive #");
        writeDecFn(i + 1);
        writeFn(" (");
        // Print block device name
        var n_len: usize = 0;
        while (n_len < d.block_dev.name.len and d.block_dev.name[n_len] != 0) : (n_len += 1) {}
        writeFn(d.block_dev.name[0..n_len]);
        writeFn("):\n");

        writeFn("    Vendor:       ");
        writeFn(&d.vendor);
        writeFn("\n");

        writeFn("    Product:      ");
        writeFn(&d.product);
        writeFn("\n");

        writeFn("    Revision:     ");
        writeFn(&d.revision);
        writeFn("\n");

        writeFn("    Capacity:     ");
        const size_mb = (d.total_sectors * d.sector_size) / (1024 * 1024);
        writeDecFn(size_mb);
        writeFn(" MB (");
        writeDecFn(d.total_sectors);
        writeFn(" sectors x ");
        writeDecFn(d.sector_size);
        writeFn(" bytes)\n");

        writeFn("    USB Address:  Device ");
        writeDecFn(d.dev.addr);
        writeFn(" (Controller #");
        writeDecFn(d.dev.ctrl_idx);
        writeFn(", Port ");
        writeDecFn(d.dev.port);
        writeFn(")\n");

        writeFn("    Endpoints:    Bulk-IN EP ");
        writeDecFn(d.dev.ep_bulk_in);
        writeFn(", Bulk-OUT EP ");
        writeDecFn(d.dev.ep_bulk_out);
        writeFn("\n\n");
    }
}
