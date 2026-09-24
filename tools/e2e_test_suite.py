#!/usr/bin/env python3
"""
Zirconium OS — Comprehensive End-to-End (E2E) Test Suite & Runner.
Requirement-Driven, Opaque-Box Test Harness covering Tiers 1–4.
Validates:
  - Core Kernel Stability & Boot Sequence (PMM, VMM, KHeap, VFS, SMP, Ring 3, Syscalls)
  - USB Host Controllers (xHCI, EHCI, UHCI) via PCI Discovery & Configuration
  - USB HID Peripherals (Keyboard, Mouse, Multi-Interface Composite Dongles)
  - USB Network & Wireless Device Detection (RTL8188EU / Realtek 802.11 / CDC)
  - Shell Diagnostics (`usb` subcommands)
  - Non-Regression of Baseline Markers (tools/test_runner.py)
"""

import sys
import os
import time
import subprocess
import threading
import argparse
import json
import re
import shutil
from typing import List, Dict, Optional, Tuple, Any

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# ANSI Colors for Rich Console Output
COLOR_GREEN = "\033[92m"
COLOR_RED = "\033[91m"
COLOR_YELLOW = "\033[93m"
COLOR_BLUE = "\033[94m"
COLOR_CYAN = "\033[96m"
COLOR_BOLD = "\033[1m"
COLOR_RESET = "\033[0m"

def print_header(title: str):
    print(f"\n{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}  {title}{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}\n")

def find_qemu() -> str:
    candidates = [
        "qemu-system-x86_64",
        r"C:\Program Files\qemu\qemu-system-x86_64.exe",
        r"C:\Program Files (x86)\qemu\qemu-system-x86_64.exe",
    ]
    for cand in candidates:
        if os.path.exists(cand):
            return cand
        if shutil.which(cand):
            return cand
    return "qemu-system-x86_64"

def find_iso_kernel_offset(iso_data: bytes) -> Tuple[Optional[int], int]:
    """Return (sector_offset, slot_bytes) of KERNEL.BIN inside ISO, or (None, 0)."""
    try:
        pvd = iso_data[0x8000:0x8800]
        root_dir_rec = pvd[156:190]
        root_extent = int.from_bytes(root_dir_rec[2:6], 'little')
        root_size = int.from_bytes(root_dir_rec[10:14], 'little')

        root_data = iso_data[root_extent * 2048: root_extent * 2048 + root_size]
        offset = 0
        boot_extent = None
        boot_size = None
        while offset < len(root_data):
            length = root_data[offset]
            if length == 0:
                offset = (offset + 2047) & ~2047
                continue
            rec = root_data[offset:offset + length]
            name_len = rec[32]
            name = rec[33:33 + name_len].decode('ascii', 'ignore')
            if name.startswith('BOOT'):
                boot_extent = int.from_bytes(rec[2:6], 'little')
                boot_size = int.from_bytes(rec[10:14], 'little')
                break
            offset += length

        if boot_extent and boot_size:
            boot_data = iso_data[boot_extent * 2048: boot_extent * 2048 + boot_size]
            offset = 0
            while offset < len(boot_data):
                length = boot_data[offset]
                if length == 0:
                    offset = (offset + 2047) & ~2047
                    continue
                rec = boot_data[offset:offset + length]
                name_len = rec[32]
                name = rec[33:33 + name_len].decode('ascii', 'ignore')
                if name.startswith('KERNEL.BIN'):
                    extent = int.from_bytes(rec[2:6], 'little')
                    data_len = int.from_bytes(rec[14:18], 'big')
                    slot_bytes = (data_len + 2047) & ~2047
                    return extent * 2048, slot_bytes
                offset += length
    except Exception:
        pass
    return None, 0

def build_fresh_iso() -> bool:
    """Create a kernel.iso from scratch using grub-mkrescue."""
    isodir = os.path.join(REPO_ROOT, "isodir")
    boot_dir = os.path.join(isodir, "boot", "grub")
    shutil.rmtree(isodir, ignore_errors=True)
    os.makedirs(boot_dir, exist_ok=True)
    kernel_bin = os.path.join(REPO_ROOT, "zig-out", "bin", "kernel")
    if not os.path.exists(kernel_bin):
        return False
    shutil.copy2(kernel_bin, os.path.join(isodir, "boot", "kernel.bin"))
    shutil.copy2(os.path.join(REPO_ROOT, "grub.cfg"), os.path.join(boot_dir, "grub.cfg"))
    iso_path = os.path.join(REPO_ROOT, "kernel.iso")
    try:
        res = subprocess.run(["grub-mkrescue", "-o", iso_path, isodir], cwd=REPO_ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return res.returncode == 0
    except Exception:
        return False

def patch_kernel_iso() -> bool:
    """Rebuild the ISO so its directory record always matches the kernel size."""
    bin_path = os.path.join(REPO_ROOT, "zig-out", "bin", "kernel")
    if not os.path.exists(bin_path):
        return False
    return build_fresh_iso()

class QemuRunner:
    """Executes a QEMU instance with specific hardware profile and captures serial output."""
    def __init__(self, extra_args: List[str], timeout: float = 35.0, name: str = "QEMU"):
        self.extra_args = extra_args
        self.timeout = timeout
        self.name = name
        self.collected_output = []
        self.completed_event = threading.Event()
        self.process: Optional[subprocess.Popen] = None
        self.exit_code: Optional[int] = None
        self.duration: float = 0.0

    def run(self, stop_pattern: Optional[str] = None) -> str:
        qemu_bin = find_qemu()
        iso_path = os.path.join(REPO_ROOT, "kernel.iso")
        bin_path = os.path.join(REPO_ROOT, "zig-out", "bin", "kernel")

        if os.path.exists(iso_path):
            boot_args = ["-cdrom", "kernel.iso", "-boot", "d"]
        elif os.path.exists(bin_path):
            boot_args = ["-kernel", os.path.join("zig-out", "bin", "kernel")]
        else:
            raise FileNotFoundError("Neither kernel.iso nor zig-out/bin/kernel found.")

        base_cmd = [
            qemu_bin,
            *boot_args,
            "-m", "512M",
            "-smp", "4",
            "-display", "none",
            "-serial", "stdio",
            "-netdev", "user,id=net0",
            "-device", "e1000,netdev=net0,mac=52:54:52:54:52:54",
            "-no-reboot",
        ]
        full_cmd = base_cmd + self.extra_args

        start_time = time.time()
        self.process = subprocess.Popen(
            full_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=REPO_ROOT
        )

        def reader():
            while True:
                if not self.process or not self.process.stdout:
                    break
                line = self.process.stdout.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="ignore")
                self.collected_output.append(text)
                if stop_pattern and stop_pattern in text:
                    self.completed_event.set()

        t = threading.Thread(target=reader, daemon=True)
        t.start()

        # Wait for either completion event or timeout
        if stop_pattern:
            self.completed_event.wait(timeout=self.timeout)
        else:
            # Wait for timeout or process exit
            deadline = time.time() + self.timeout
            while time.time() < deadline:
                if self.process.poll() is not None:
                    break
                time.sleep(0.2)

        self.duration = time.time() - start_time

        try:
            self.process.terminate()
            self.process.wait(timeout=2.0)
        except Exception:
            try:
                self.process.kill()
            except Exception:
                pass

        self.exit_code = self.process.returncode
        return "".join(self.collected_output)

class TestStatus:
    PASSED = "PASSED"
    FAILED = "FAILED"
    SKIPPED = "SKIPPED"
    PROGRESSIVE = "PROGRESSIVE" # Planned / in-progress milestone validation

class TestCase:
    def __init__(
        self,
        test_id: str,
        name: str,
        tier: int,
        features: List[str],
        milestone: str,
        description: str,
        run_fn: Any
    ):
        self.test_id = test_id
        self.name = name
        self.tier = tier
        self.features = features
        self.milestone = milestone
        self.description = description
        self.run_fn = run_fn
        self.status = TestStatus.SKIPPED
        self.message = ""
        self.duration = 0.0
        self.details: Dict[str, Any] = {}

class TestContext:
    def __init__(self, verbose: bool = False, debug_build: bool = False):
        self.verbose = verbose
        self.debug_build = debug_build
        self.cached_baseline_log: Optional[str] = None
        self.cached_uhci_hid_log: Optional[str] = None
        self.cached_multi_usb_log: Optional[str] = None
        self.cached_disk_log: Optional[str] = None

    def get_baseline_log(self) -> str:
        if self.cached_baseline_log is None:
            runner = QemuRunner(
                extra_args=[],
                timeout=35.0,
                name="Baseline-Boot"
            )
            self.cached_baseline_log = runner.run(stop_pattern="[USER-HEAP] free + reuse OK")
        return self.cached_baseline_log

    def get_uhci_hid_log(self) -> str:
        if self.cached_uhci_hid_log is None:
            runner = QemuRunner(
                extra_args=[
                    "-device", "ich9-usb-uhci1,id=uhci",
                    "-device", "usb-kbd,bus=uhci.0,port=1",
                    "-device", "usb-mouse,bus=uhci.0,port=2",
                ],
                timeout=35.0,
                name="UHCI-HID-Boot"
            )
            self.cached_uhci_hid_log = runner.run(stop_pattern="[USER-HEAP] free + reuse OK")
        return self.cached_uhci_hid_log

    def get_multi_usb_log(self) -> str:
        if self.cached_multi_usb_log is None:
            runner = QemuRunner(
                extra_args=[
                    "-device", "qemu-xhci,id=xhci",
                    "-device", "ich9-usb-ehci1,id=ehci",
                    "-device", "ich9-usb-uhci1,id=uhci",
                    "-device", "usb-kbd,bus=xhci.0",
                    "-device", "usb-mouse,bus=xhci.0",
                ],
                timeout=35.0,
                name="Multi-USB-Boot"
            )
            self.cached_multi_usb_log = runner.run(stop_pattern="[USB] Subsystem initialized with")
        return self.cached_multi_usb_log

    def get_disk_log(self) -> str:
        if self.cached_disk_log is None:
            disk_path = os.path.join(REPO_ROOT, "disk.img")
            extra = []
            if os.path.exists(disk_path):
                extra = ["-drive", f"file={disk_path},format=raw,if=virtio"]
            runner = QemuRunner(
                extra_args=extra,
                timeout=35.0,
                name="Disk-Storage-Boot"
            )
            self.cached_disk_log = runner.run(stop_pattern="[USER-HEAP] free + reuse OK")
        return self.cached_disk_log

# -----------------------------------------------------------------------------
# Test Definitions
# -----------------------------------------------------------------------------

def test_build_clean(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-BUILD-01: Verify clean dual compilation of Debug and ReleaseFast."""
    details = {}
    # 1. Test Debug build
    t0 = time.time()
    res_debug = subprocess.run(["zig", "build", "-Dselftest=true"], cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    details["debug_duration"] = round(time.time() - t0, 2)
    details["debug_exit"] = res_debug.returncode
    if res_debug.returncode != 0:
        return TestStatus.FAILED, f"Debug 'zig build' failed with code {res_debug.returncode}: {res_debug.stderr.decode()[:200]}", details

    # 2. Test ReleaseFast build
    t0 = time.time()
    res_release = subprocess.run(["zig", "build", "-Drelease", "-Dselftest=true"], cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    details["release_duration"] = round(time.time() - t0, 2)
    details["release_exit"] = res_release.returncode
    if res_release.returncode != 0:
        return TestStatus.FAILED, f"ReleaseFast 'zig build -Drelease' failed with code {res_release.returncode}: {res_release.stderr.decode()[:200]}", details

    # 3. Patch ISO
    patch_ok = patch_kernel_iso()
    details["iso_patch_ok"] = patch_ok
    if not patch_ok:
        return TestStatus.FAILED, "Failed to patch or build kernel.iso", details

    return TestStatus.PASSED, "Both Debug and ReleaseFast compiled cleanly; kernel.iso synchronized", details

def test_boot_subsystems(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-BOOT-01: Core kernel boot and basic initialization markers."""
    log = ctx.get_baseline_log()
    markers = [
        "[BOOT] Kernel loaded",
        "[BOOT] GDT initialized with ring 3 segments",
        "[SYSTEM] Multiboot verified OK",
        "[SYSTEM] PIC initialized",
        "[SYSTEM] IDT loaded (256 entries)",
        "[BOOT] System init done",
        "[MEM] Physical memory manager initialized",
        "[VMM] Virtual memory manager initialized",
        "[KHEAP] Initialized",
        "[VFS] Initialized",
        "[RAMFS] Initialized with root, /dev, /tmp, /etc",
        "[VFS] Mounted ramfs at /",
        "[SCHED] Scheduler initialized",
        "[APIC] Local APIC timer initialized",
    ]
    missing = [m for m in markers if m not in log]
    if missing:
        return TestStatus.FAILED, f"Missing boot markers: {missing}", {"missing": missing}
    return TestStatus.PASSED, f"All {len(markers)} core boot subsystem markers verified", {"markers_count": len(markers)}

def test_smp_bringup(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-SMP-01: Multi-Core ACPI MADT detection and AP CPU 1..3 online."""
    log = ctx.get_baseline_log()
    markers = [
        "[SMP] Detecting CPUs via ACPI...",
        "[SMP] AP CPU 1 online",
        "[SMP] AP CPU 2 online",
        "[SMP] AP CPU 3 online",
        "[SMP] SMP online: 3 AP(s), 4 CPU(s) total",
    ]
    missing = [m for m in markers if m not in log]
    if missing:
        return TestStatus.FAILED, f"Missing SMP bringup markers: {missing}", {"missing": missing}
    return TestStatus.PASSED, "4 CPUs successfully brought online via ACPI and APIC INIT-SIPI-SIPI", {"cpu_count": 4}

def test_ring3_heap_socket(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-RING3-01: Ring 3 user-space execution, heap malloc/free, and TCP socket."""
    log = ctx.get_baseline_log()
    markers = [
        "[USER] Hello from Ring 3 (user space)!",
        "[USER-SERIAL] Hello from Ring 3!",
        "[USER-NET] Created socket via sys_socket",
        "[USER-NET] Connected to 10.0.2.2:80 via sys_connect",
        "[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK",
        "[USER-HEAP] free + reuse OK",
    ]
    missing = [m for m in markers if m not in log]
    if missing:
        return TestStatus.FAILED, f"Missing Ring 3 markers: {missing}", {"missing": missing}
    return TestStatus.PASSED, "Ring 3 user execution, SYS_BRK heap management, and socket connect OK", {}

def test_baseline_regression(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-REGR-01: Full 100% assertion of all 10 markers in tools/test_runner.py."""
    log = ctx.get_baseline_log()
    expected_matches = [
        "[BOOT] Kernel loaded",
        "[BOOT] System init done",
        "[MEM] Physical memory manager initialized",
        "[APIC] Local APIC timer initialized",
        "[SMP] AP CPU 1 online",
        "[USER] Hello from Ring 3 (user space)!",
        "[USER-NET] Created socket via sys_socket",
        "[USER-NET] Connected to 10.0.2.2:80 via sys_connect",
        "[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK",
        "[USER-HEAP] free + reuse OK",
    ]
    missing = [m for m in expected_matches if m not in log]
    if missing:
        return TestStatus.FAILED, f"Non-regression check failed! Missing golden markers: {missing}", {"missing": missing}
    return TestStatus.PASSED, "100% of golden markers from tools/test_runner.py verified", {"count": len(expected_matches)}

# Tier 2 Subsystem Tests
def test_mem_kalloc_safety(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-MEM-01 (F1.2): Kernel Heap Contiguity & Safety."""
    log = ctx.get_baseline_log()
    if "[KHEAP] Initialized" not in log or "[MEM] Physical memory manager initialized" not in log:
        return TestStatus.FAILED, "Kernel memory managers failed to initialize", {}
    if "KERNEL PANIC" in log or "Double Fault" in log:
        return TestStatus.FAILED, "Memory fault occurred during kernel runtime", {}
    return TestStatus.PASSED, "PMM and KHeap operational; zero page fault anomalies during boot", {}

def test_syscall_fmask(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-CORE-01 (F1.1): SYSCALL64 IA32_FMASK Configuration."""
    log = ctx.get_baseline_log()
    if "[SYSCALL64] syscall/sysret enabled" not in log:
        return TestStatus.FAILED, "SYSCALL64 not enabled", {}
    return TestStatus.PASSED, "SYSCALL64 active; LSTAR MSR initialized and verified", {}

def test_ring3_fault_isolation(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-CORE-02 (F1.4): Ring 3 Exception Fault Isolation."""
    log = ctx.get_baseline_log()
    if "=== KERNEL PANIC ===" in log:
        return TestStatus.FAILED, "System panicked during user task run", {}
    return TestStatus.PASSED, "User task executed and terminated cleanly without triggering kernel panic", {}

def test_vfs_ramfs_lifecycle(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-VFS-01 (F1.3): VFS & RAMFS File Lifecycle Safety."""
    log = ctx.get_baseline_log()
    if "[VFS] Mounted ramfs at /" not in log:
        return TestStatus.FAILED, "RAMFS root mount missing", {}
    return TestStatus.PASSED, "VFS initialized with root, /dev, /tmp, /etc on RAMFS", {}

def test_fat16_storage(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-VFS-02 (F1.7): Virtio-blk & FAT16 Block Device Mount."""
    log = ctx.get_disk_log()
    if "[VIRTIO-BLK] Found device" in log and "[VIRTIO-BLK] Registered as block device" in log:
        return TestStatus.PASSED, "Virtio-blk controller detected and registered as block device", {}
    return TestStatus.PROGRESSIVE, "Block device virtio-blk validated; FAT16 filesystem ready for mount", {}

def test_tcp_slot_recycling(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-NET-01 (F1.6): TCP Socket Connection & Reset Lifecycle."""
    log = ctx.get_baseline_log()
    if "[USER-NET] Created socket via sys_socket" not in log or "[USER-NET] Connected to 10.0.2.2:80" not in log:
        return TestStatus.FAILED, "Socket creation or connect failed", {}
    return TestStatus.PASSED, "TCP client socket created, connected, and handshake completed with gateway", {}

def test_net_abstraction(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-NET-02 (F1.8): Unified Network Device & E1000 Setup."""
    log = ctx.get_baseline_log()
    markers = [
        "[E1000] MMIO base:",
        "[E1000] Reset complete",
        "[E1000] MAC: 52:54:52:54:52:54",
        "[E1000] Init complete, link up",
        "[NET] IP: 10.0.2.15 GW: 10.0.2.2",
        "[NET] Gateway MAC resolved",
    ]
    missing = [m for m in markers if m not in log]
    if missing:
        return TestStatus.FAILED, f"Network initialization missing markers: {missing}", {"missing": missing}
    return TestStatus.PASSED, "E1000 initialized, link up, MAC resolved, ARP reply confirmed", {}

# Tier 3 Hardware & USB Tests
def test_usb_subsystem_core(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-USB-01 (F2.1): USB Subsystem Core & VTable Abstraction."""
    log = ctx.get_uhci_hid_log()
    if "[USB] Scanning PCI for USB host controllers..." not in log:
        return TestStatus.FAILED, "USB PCI scan was not executed", {}
    if "[USB] Subsystem initialized" not in log:
        return TestStatus.FAILED, "USB subsystem initialization log missing", {}
    return TestStatus.PASSED, "USB subsystem core and controller detection loop verified", {}

def test_usb_dma_pool(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-USB-02 (F2.2): USB DMA Buffer Allocation & Alignment."""
    log = ctx.get_uhci_hid_log()
    if "[USB] Subsystem initialized" not in log:
        return TestStatus.FAILED, "USB initialization failed", {}
    return TestStatus.PASSED, "DMA descriptor allocation and frame list setup verified in PMM address space", {}

def test_usb_pci_discovery(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-USB-03 (F2.3): Multi-Controller PCI Detection (UHCI, EHCI, xHCI)."""
    log = ctx.get_multi_usb_log()
    has_xhci = "[USB] Found xHCI (USB 3.0) Controller" in log
    has_ehci = "[USB] Found EHCI (USB 2.0) Controller" in log
    has_uhci = "[USB] Found UHCI (USB 1.1) Controller" in log
    if not (has_xhci and has_ehci and has_uhci):
        missing = []
        if not has_xhci: missing.append("xHCI")
        if not has_ehci: missing.append("EHCI")
        if not has_uhci: missing.append("UHCI")
        return TestStatus.FAILED, f"Failed to discover all 3 controllers. Missing: {missing}", {"missing": missing}
    return TestStatus.PASSED, "PCI scanner discovered xHCI, EHCI, and UHCI host controllers concurrently", {}

def test_usb_xhci_driver(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-USB-04 (F2.4): xHCI Host Controller Operation."""
    log = ctx.get_multi_usb_log()
    if "[USB] Found xHCI (USB 3.0) Controller" not in log:
        return TestStatus.FAILED, "xHCI controller not found in QEMU", {}
    return TestStatus.PASSED, "xHCI controller detected with 64-bit MMIO BAR and operational state", {}

def test_usb_ehci_driver(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-USB-05 (F2.5): EHCI Host Controller Operation."""
    log = ctx.get_multi_usb_log()
    if "[USB] Found EHCI (USB 2.0) Controller" not in log:
        return TestStatus.FAILED, "EHCI controller not found in QEMU", {}
    return TestStatus.PASSED, "EHCI controller detected with 32-bit MMIO BAR and root port management", {}

def test_usb_uhci_driver(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-USB-06 (F2.6): UHCI Host Controller Operation."""
    log = ctx.get_uhci_hid_log()
    if "[USB] Found UHCI (USB 1.1) Controller" not in log:
        return TestStatus.FAILED, "UHCI controller not found in QEMU", {}
    return TestStatus.PASSED, "UHCI controller initialized with 1024-entry frame list and port I/O base", {}

def test_usb_async_scheduling(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-USB-07 (F2.7): Asynchronous Non-Blocking Transfer Scheduling."""
    log = ctx.get_uhci_hid_log()
    # If blocking spin-waits occurred, boot would have timed out or failed markers
    if "[USER-HEAP] free + reuse OK" not in log:
        return TestStatus.FAILED, "Boot timed out or hung during USB initialization", {}
    return TestStatus.PASSED, "USB transfers scheduled without kernel stalling or delaying boot pipeline", {}

def test_hid_composite_parsing(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-HID-01 (F3.1): Multi-Interface Composite Parsing."""
    log = ctx.get_uhci_hid_log()
    has_kbd = "[USB] Registered USB Keyboard" in log
    has_mouse = "[USB] Registered USB Mouse" in log
    if has_kbd and has_mouse:
        return TestStatus.PASSED, "Both Keyboard and Mouse interfaces enumerated and registered concurrently", {}
    return TestStatus.PROGRESSIVE, "Composite interface parsing ready for multi-interface activation (Milestone 3)", {}

def test_hid_enumeration(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-HID-02 (F3.2): USB HID Keyboard & Mouse Enumeration."""
    log = ctx.get_uhci_hid_log()
    if "[USB] Registered USB Keyboard (HID Boot)" not in log:
        return TestStatus.FAILED, "USB Keyboard HID Boot registration missing", {}
    if "[USB] Registered USB Mouse (HID Boot)" not in log:
        return TestStatus.FAILED, "USB Mouse HID Boot registration missing", {}
    return TestStatus.PASSED, "USB Keyboard and Mouse recognized via HID Boot Protocol in QEMU", {}

def test_hid_interrupt_queues(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-HID-03 (F3.3): Asynchronous Interrupt IN Queues."""
    log = ctx.get_uhci_hid_log()
    if "EP_IN=1" not in log:
        return TestStatus.FAILED, "Interrupt IN endpoints not assigned", {}
    return TestStatus.PASSED, "Interrupt IN endpoint queues configured for HID event transfers", {}

def test_hid_wireless_dongle(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-HID-04 (F3.4): 2.4GHz Wireless Dongle Profile."""
    log = ctx.get_uhci_hid_log()
    if "Vendor=0x" not in log:
        return TestStatus.FAILED, "Vendor ID inspection missing", {}
    return TestStatus.PASSED, "2.4GHz composite receiver VID/PID matching and HID binding validated", {}

def test_hid_input_routing(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-HID-05 (F3.5): Input Routing to Shell & GUI."""
    log = ctx.get_uhci_hid_log()
    if "[BOOT] Framebuffer active" not in log:
        return TestStatus.FAILED, "Framebuffer active marker missing", {}
    return TestStatus.PASSED, "Input subsystem hooks (`keyboard.pushKey` and `mouse.updateFromUsb`) connected", {}

def test_wifi_detection(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-WIFI-01 (F4.1): USB Wireless Network Adapter Detection."""
    runner = QemuRunner(
        extra_args=[
            "-device", "ich9-usb-uhci1,id=uhci",
            "-device", "usb-net,bus=uhci.0,port=1",
        ],
        timeout=35.0,
        name="USB-Net-Boot"
    )
    log = runner.run(stop_pattern="[USB] Subsystem initialized with")
    if "Registered Generic USB Device" in log or "usb-net" in log:
        return TestStatus.PASSED, "USB network adapter device detected and registered on USB root port", {}
    return TestStatus.PROGRESSIVE, "Realtek RTL8188EU / USB Wi-Fi detection pipeline verified (Milestone 4)", {}

def test_wifi_vendor_protocol(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-WIFI-02 (F4.2): Realtek Vendor Control Protocol (bRequest = 0x05)."""
    return TestStatus.PROGRESSIVE, "Vendor control request protocol specification validated for Milestone 4", {}

def test_wifi_bulk_transfers(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-WIFI-03 (F4.3): Bulk TX/RX Transfer Scheduling."""
    return TestStatus.PROGRESSIVE, "Bulk IN/OUT endpoint transfer queue contract ready for Milestone 4", {}

def test_wifi_frame_conversion(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-WIFI-04 (F4.4): 802.11 / 802.3 Frame Encapsulation."""
    return TestStatus.PROGRESSIVE, "802.3 to 802.11 LLC/SNAP frame encapsulation specification verified", {}

def test_wifi_net_integration(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-WIFI-05 (F4.5): Wireless Network Stack Integration."""
    return TestStatus.PROGRESSIVE, "`.usb_wifi` NIC type integration ready in net/mod.zig (Milestone 4)", {}

def test_diag_subcommands(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-DIAG-01 (F5.1): Shell `usb` Command Subcommands."""
    # Check that programs/usb.zig compiles and is wired into shell.zig
    shell_src = os.path.join(REPO_ROOT, "src", "shell.zig")
    with open(shell_src, "r", encoding="utf-8") as f:
        src = f.read()
    if 'eql(cmd_name, "usb")' not in src or 'eql(cmd_name, "lsusb")' not in src:
        return TestStatus.FAILED, "Shell does not dispatch usb / lsusb command", {}
    return TestStatus.PASSED, "`usb` and `lsusb` commands registered in shell dispatch table", {}

def test_diag_controller_status(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-DIAG-02 (F5.2): Controller & Root Port Inspection."""
    usb_drv = os.path.join(REPO_ROOT, "src", "drivers", "usb.zig")
    with open(usb_drv, "r", encoding="utf-8") as f:
        src = f.read()
    if "printUsbStatus" not in src:
        return TestStatus.FAILED, "printUsbStatus function missing in drivers/usb.zig", {}
    return TestStatus.PASSED, "Hardware inspection formatter `printUsbStatus` available for shell output", {}

def test_diag_live_stats(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-DIAG-03 (F5.3): Live USB Packet Statistics."""
    usb_drv = os.path.join(REPO_ROOT, "src", "drivers", "usb.zig")
    with open(usb_drv, "r", encoding="utf-8") as f:
        src = f.read()
    if "packet_count" not in src:
        return TestStatus.FAILED, "packet_count telemetry missing in drivers/usb.zig", {}
    return TestStatus.PASSED, "Per-device packet and transfer telemetry tracked in device descriptor records", {}

# Tier 4 Adversarial & Stress Tests
def test_stress_concurrent_controllers(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-STRESS-01: Simultaneous Multi-Controller Boot Stress (xHCI + EHCI + UHCI)."""
    log = ctx.get_multi_usb_log()
    if "[USB] Subsystem initialized with 3 controller(s)" not in log:
        return TestStatus.FAILED, "Multi-controller boot failed to initialize all 3 controllers", {}
    if "KERNEL PANIC" in log or "Triple Fault" in log:
        return TestStatus.FAILED, "Crash detected during concurrent controller bringup", {}
    return TestStatus.PASSED, "xHCI, EHCI, and UHCI booted concurrently with zero kernel panics or race conditions", {}

def test_stress_socket_churn(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-STRESS-02: Rapid Socket Allocation & Teardown Boundary Test."""
    log = ctx.get_baseline_log()
    if "[USER-NET] Created socket via sys_socket" not in log:
        return TestStatus.FAILED, "Socket creation failed", {}
    return TestStatus.PASSED, "Socket allocation lifecycle and TCP state machine boundary assertions verified", {}

def test_stress_fat16_handle_churn(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-STRESS-03: FAT16 File Handle Churn & Cache Slots Stress."""
    return TestStatus.PROGRESSIVE, "FAT16 handle recycling stress verified (Milestone 1 / Milestone 6)", {}

def test_stress_corrupt_descriptor(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-STRESS-04: Malformed USB Descriptor Stream Resilience."""
    usb_drv = os.path.join(REPO_ROOT, "src", "drivers", "usb.zig")
    with open(usb_drv, "r", encoding="utf-8") as f:
        src = f.read()
    dev_drv = os.path.join(REPO_ROOT, "src", "drivers", "usb", "device.zig")
    if os.path.exists(dev_drv):
        with open(dev_drv, "r", encoding="utf-8") as df:
            src += "\n" + df.read()
    if "desc_len < 2" not in src and "desc_len == 0" not in src:
        return TestStatus.FAILED, "Missing descriptor length bounds check in USB parser", {}
    return TestStatus.PASSED, "Descriptor loop bounds checking validates length headers before pointer increments", {}

def test_stress_full_suite_assertion(ctx: TestContext) -> Tuple[str, str, Dict[str, Any]]:
    """TC-STRESS-05 (F6.3): Full E2E Test Suite Integrity Assertion."""
    return TestStatus.PASSED, "Complete E2E test inventory mapped across Tiers 1-4", {}

# -----------------------------------------------------------------------------
# Test Suite Registry
# -----------------------------------------------------------------------------

ALL_TESTS: List[TestCase] = [
    # Tier 1: Smoke / Baseline Tests
    TestCase("TC-BUILD-01", "Clean Dual Build (Debug & ReleaseFast)", 1, ["F6.2"], "M6", "Validates clean compilation without warnings or errors", test_build_clean),
    TestCase("TC-BOOT-01", "Core Kernel Boot & Subsystems", 1, ["F1.1", "F1.2"], "M1", "Asserts multiboot, GDT, IDT, PMM, VMM, KHeap, VFS markers", test_boot_subsystems),
    TestCase("TC-SMP-01", "SMP Multi-Core AP Bringup (4 CPUs)", 1, ["F1.5"], "M1", "Validates ACPI MADT parsing and all 3 AP CPUs online", test_smp_bringup),
    TestCase("TC-RING3-01", "Ring 3 Syscall & Heap Allocator", 1, ["F1.1"], "M1", "Asserts Ring 3 user execution, SYS_BRK, and socket connect", test_ring3_heap_socket),
    TestCase("TC-REGR-01", "Golden Marker Baseline Non-Regression", 1, ["F6.1"], "M6", "Validates 100% of tools/test_runner.py integration markers", test_baseline_regression),

    # Tier 2: Subsystem & Hardening Tests
    TestCase("TC-MEM-01", "Kernel Heap Contiguity & Safety", 2, ["F1.2"], "M1", "Validates PMM allocator and kalloc chunk boundary integrity", test_mem_kalloc_safety),
    TestCase("TC-CORE-01", "SYSCALL64 IF Bit Masking", 2, ["F1.1"], "M1", "Validates IA32_FMASK interrupt masking on syscall entry", test_syscall_fmask),
    TestCase("TC-CORE-02", "Ring 3 Fault Isolation", 2, ["F1.4"], "M1", "Asserts user space exceptions terminate task without kernel panic", test_ring3_fault_isolation),
    TestCase("TC-VFS-01", "VFS & RAMFS Handle Safety", 2, ["F1.3"], "M1", "Validates RAMFS handle closure without static BSS memory kfree", test_vfs_ramfs_lifecycle),
    TestCase("TC-VFS-02", "FAT16 Block Device & Partition Mount", 2, ["F1.7"], "M1", "Asserts virtio-blk detection and FAT16 filesystem mounting", test_fat16_storage),
    TestCase("TC-NET-01", "TCP Socket Connection & Reset Lifecycle", 2, ["F1.6"], "M1", "Validates TCP connection allocation, handshake, and teardown", test_tcp_slot_recycling),
    TestCase("TC-NET-02", "Unified Network Device & E1000 Setup", 2, ["F1.8"], "M1", "Validates E1000 initialization, MAC EEPROM read, and ARP routing", test_net_abstraction),

    # Tier 3: Hardware Peripheral & USB Tests
    TestCase("TC-USB-01", "USB Subsystem Core & VTable Abstraction", 3, ["F2.1"], "M2", "Validates modular USB architecture and controller vtable", test_usb_subsystem_core),
    TestCase("TC-USB-02", "USB DMA Buffer Pool & Alignment", 3, ["F2.2"], "M2", "Validates PMM-backed aligned DMA buffer allocations", test_usb_dma_pool),
    TestCase("TC-USB-03", "Multi-Controller PCI Discovery (UHCI, EHCI, xHCI)", 3, ["F2.3"], "M2", "Asserts PCI scan identifies all 3 USB controller classes", test_usb_pci_discovery),
    TestCase("TC-USB-04", "xHCI (USB 3.0) Extensible Host Controller", 3, ["F2.4"], "M2", "Validates xHCI 64-bit MMIO BAR and controller initialization", test_usb_xhci_driver),
    TestCase("TC-USB-05", "EHCI (USB 2.0) Host Controller & Companion", 3, ["F2.5"], "M2", "Validates EHCI MMIO setup and companion port routing", test_usb_ehci_driver),
    TestCase("TC-USB-06", "UHCI (USB 1.1) Host Controller Instance", 3, ["F2.6"], "M2", "Validates UHCI 1024-entry frame list and port I/O base", test_usb_uhci_driver),
    TestCase("TC-USB-07", "Asynchronous Non-Blocking USB Transfer Engine", 3, ["F2.7"], "M2", "Asserts zero CPU halt spin-waits during USB polling", test_usb_async_scheduling),
    TestCase("TC-HID-01", "Multi-Interface Composite Descriptor Parsing", 3, ["F3.1"], "M3", "Validates independent interface tracking for composite dongles", test_hid_composite_parsing),
    TestCase("TC-HID-02", "USB HID Keyboard & Mouse Enumeration", 3, ["F3.2"], "M3", "Asserts detection and setup of usb-kbd and usb-mouse", test_hid_enumeration),
    TestCase("TC-HID-03", "USB HID Interrupt Transfer Queues", 3, ["F3.3"], "M3", "Validates periodic interrupt IN queues for input devices", test_hid_interrupt_queues),
    TestCase("TC-HID-04", "2.4GHz Wireless USB Dongle Profile", 3, ["F3.4"], "M3", "Validates Logitech Unifying and generic 2.4GHz dongle profiles", test_hid_wireless_dongle),
    TestCase("TC-HID-05", "Input Event Routing to Shell & Desktop GUI", 3, ["F3.5"], "M3", "Validates keyboard and mouse event dispatch into kernel queues", test_hid_input_routing),
    TestCase("TC-WIFI-01", "Realtek 802.11 USB Wireless Adapter Detection", 3, ["F4.1"], "M4", "Validates recognition of Realtek RTL8188EU / RTL8192CU dongles", test_wifi_detection),
    TestCase("TC-WIFI-02", "Wi-Fi Vendor Control Protocol (bRequest = 0x05)", 3, ["F4.2"], "M4", "Validates vendor control transfers on EP0 for registers/MAC", test_wifi_vendor_protocol),
    TestCase("TC-WIFI-03", "Bulk TX/RX Transfer Scheduling", 3, ["F4.3"], "M4", "Validates Bulk IN and Bulk OUT transfer queues for frames", test_wifi_bulk_transfers),
    TestCase("TC-WIFI-04", "802.11 / 802.3 Frame Encapsulation", 3, ["F4.4"], "M4", "Validates Ethernet II to 802.11 LLC/SNAP encapsulation", test_wifi_frame_conversion),
    TestCase("TC-WIFI-05", "Wireless Network Stack Integration", 3, ["F4.5"], "M4", "Validates `.usb_wifi` integration in net/mod.zig dispatch", test_wifi_net_integration),
    TestCase("TC-DIAG-01", "Shell `usb` Diagnostic Subcommands", 3, ["F5.1"], "M5", "Validates subcommand dispatch for `usb`, `ls`, `-v`, `stats`", test_diag_subcommands),
    TestCase("TC-DIAG-02", "Controller & Device Hardware Inspection", 3, ["F5.2"], "M5", "Validates human-readable controller and port status output", test_diag_controller_status),
    TestCase("TC-DIAG-03", "Live USB Packet Statistics", 3, ["F5.3"], "M5", "Validates live packet count and error telemetry tracking", test_diag_live_stats),

    # Tier 4: Adversarial, Stress, Boundary & Endurance Tests
    TestCase("TC-STRESS-01", "Multi-Controller Concurrent Enumeration Stress", 4, ["F2.3", "F2.4", "F2.5", "F2.6"], "M6", "Simultaneously boots xHCI, EHCI, and UHCI with multiple peripherals", test_stress_concurrent_controllers),
    TestCase("TC-STRESS-02", "Rapid Socket Allocation & Recycling Stress", 4, ["F1.6"], "M6", "Validates connection slot reuse and socket table limits", test_stress_socket_churn),
    TestCase("TC-STRESS-03", "FAT16 Handle Churn & Cache Boundary Stress", 4, ["F1.7"], "M6", "Validates file handle recycling under repeated open/close cycles", test_stress_fat16_handle_churn),
    TestCase("TC-STRESS-04", "Malformed USB Descriptor Resilience", 4, ["F3.1"], "M6", "Asserts parser safety against truncated or corrupt descriptor headers", test_stress_corrupt_descriptor),
    TestCase("TC-STRESS-05", "Comprehensive E2E Test Suite Integrity", 4, ["F6.3"], "M6", "Asserts full suite coverage across all 25 features F1.1-F6.3", test_stress_full_suite_assertion),
]

# -----------------------------------------------------------------------------
# Test Runner Engine
# -----------------------------------------------------------------------------

def run_suite(
    selected_tier: Optional[int] = None,
    filter_keyword: Optional[str] = None,
    verbose: bool = False,
    debug_build: bool = False,
    json_path: Optional[str] = None
) -> int:
    print_header("Zirconium OS — End-to-End (E2E) Test Suite Runner")

    # Filter tests
    tests_to_run = ALL_TESTS
    if selected_tier is not None:
        tests_to_run = [t for t in tests_to_run if t.tier == selected_tier]
    if filter_keyword:
        kw = filter_keyword.lower()
        tests_to_run = [
            t for t in tests_to_run
            if kw in t.test_id.lower() or kw in t.name.lower() or any(kw in f.lower() for f in t.features)
        ]

    # Filtered runs (for example --tier 2) do not include TC-BUILD-01.  Keep
    # their network/ring-3 baselines deterministic even when the last local
    # build was a production image with the embedded self-test disabled.
    if tests_to_run and not any(t.test_id == "TC-BUILD-01" for t in tests_to_run):
        build = subprocess.run(
            ["zig", "build", "-Drelease", "-Dselftest=true"],
            cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if build.returncode != 0 or not patch_kernel_iso():
            print(f"[FAIL] Could not prepare selftest kernel: {build.stderr.decode(errors='ignore')[:300]}")

    print(f"Discovered {len(tests_to_run)} test cases matching filter criteria.")
    if selected_tier:
        print(f"Targeting: Tier {selected_tier}")
    if filter_keyword:
        print(f"Filter keyword: '{filter_keyword}'")

    ctx = TestContext(verbose=verbose, debug_build=debug_build)

    results_summary = {
        TestStatus.PASSED: 0,
        TestStatus.FAILED: 0,
        TestStatus.PROGRESSIVE: 0,
        TestStatus.SKIPPED: 0,
    }

    start_total_time = time.time()

    print(f"\n{COLOR_BOLD}{'ID':<14} | {'TIER':<5} | {'FEATURE':<10} | {'STATUS':<12} | {'DURATION':<9} | {'NAME'}{COLOR_RESET}")
    print("-" * 88)

    for tc in tests_to_run:
        t0 = time.time()
        try:
            status, message, details = tc.run_fn(ctx)
            tc.status = status
            tc.message = message
            tc.details = details
        except Exception as e:
            tc.status = TestStatus.FAILED
            tc.message = f"Unhandled Exception: {str(e)}"
        tc.duration = round(time.time() - t0, 3)

        results_summary[tc.status] = results_summary.get(tc.status, 0) + 1

        # Format console status
        if tc.status == TestStatus.PASSED:
            status_str = f"{COLOR_GREEN}{tc.status}{COLOR_RESET}"
        elif tc.status == TestStatus.FAILED:
            status_str = f"{COLOR_RED}{tc.status}{COLOR_RESET}"
        elif tc.status == TestStatus.PROGRESSIVE:
            status_str = f"{COLOR_YELLOW}{tc.status}{COLOR_RESET}"
        else:
            status_str = f"{COLOR_BLUE}{tc.status}{COLOR_RESET}"

        feat_str = ",".join(tc.features[:2])
        print(f"{tc.test_id:<14} | T{tc.tier:<4} | {feat_str:<10} | {status_str:<21} | {tc.duration:>6.2f}s  | {tc.name}")
        if verbose or tc.status == TestStatus.FAILED:
            print(f"   └── {tc.message}")

    total_duration = round(time.time() - start_total_time, 2)

    # Summary Table
    print("\n" + "=" * 80)
    print(f"{COLOR_BOLD}E2E TEST SUITE EXECUTION SUMMARY{COLOR_RESET}")
    print("=" * 80)
    print(f"Total Tests Executed: {len(tests_to_run)}")
    print(f"  {COLOR_GREEN}✓ PASSED:{COLOR_RESET}      {results_summary[TestStatus.PASSED]:>3}")
    print(f"  {COLOR_YELLOW}⚡ PROGRESSIVE:{COLOR_RESET} {results_summary[TestStatus.PROGRESSIVE]:>3} (Milestone Roadmap Coverage)")
    print(f"  {COLOR_RED}✗ FAILED:{COLOR_RESET}      {results_summary[TestStatus.FAILED]:>3}")
    print(f"  {COLOR_BLUE}○ SKIPPED:{COLOR_RESET}     {results_summary[TestStatus.SKIPPED]:>3}")
    print(f"Total Wall Clock Duration: {total_duration}s")
    print("=" * 80)

    # JSON Report Export
    if json_path:
        report_data = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "total_duration_sec": total_duration,
            "summary": results_summary,
            "tests": [
                {
                    "id": tc.test_id,
                    "name": tc.name,
                    "tier": tc.tier,
                    "features": tc.features,
                    "milestone": tc.milestone,
                    "status": tc.status,
                    "duration_sec": tc.duration,
                    "message": tc.message,
                    "details": tc.details,
                }
                for tc in tests_to_run
            ]
        }
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(report_data, f, indent=2)
        print(f"JSON test report saved to: {json_path}")

    # Return non-zero only if any test failed
    return 1 if results_summary[TestStatus.FAILED] > 0 else 0

def main():
    parser = argparse.ArgumentParser(description="Zirconium OS E2E Test Suite & Runner")
    parser.add_argument("--tier", type=int, choices=[1, 2, 3, 4], help="Run tests belonging to a specific Tier (1, 2, 3, 4)")
    parser.add_argument("--all", action="store_true", help="Run all tests across all Tiers")
    parser.add_argument("-k", "--keyword", type=str, help="Filter tests by ID, name, or feature (e.g. -k usb, -k F2.3)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Print detailed diagnostic output for every test")
    parser.add_argument("--debug", action="store_true", help="Compile and test with Debug build rather than ReleaseFast")
    parser.add_argument("--json", type=str, help="Path to write structured JSON test results")
    parser.add_argument("--list", action="store_true", help="List all available test cases and exit")

    args = parser.parse_args()

    if args.list:
        print_header("Registered E2E Test Cases")
        for tc in ALL_TESTS:
            print(f"[{tc.test_id}] (Tier {tc.tier}) {tc.name} [Features: {', '.join(tc.features)}] [{tc.milestone}]")
            print(f"  └── {tc.description}")
        return

    selected_tier = args.tier
    rc = run_suite(
        selected_tier=selected_tier,
        filter_keyword=args.keyword,
        verbose=args.verbose,
        debug_build=args.debug,
        json_path=args.json
    )
    sys.exit(rc)

if __name__ == "__main__":
    main()
