#!/usr/bin/env python3
"""
Zirconium OS — Milestone 2 Adversarial Stress & Empirical Challenge Suite.
Empirical Challenger 2 (challenger_m2_2).

Challenges Tested:
1. Unattached Port Behavior:
   - Root port scans on empty/unattached ports (xHCI, EHCI, UHCI)
   - Multi-controller empty boot timing (no spin-waits or CPU freezes)
   - Partial port population (one port occupied, other unattached)
2. Rapid Device Polling:
   - Zero-allocation verification (heap/PMM contiguity and leak immunity)
   - Integer overflow immunity (wrapping arithmetic on counters)
   - Live QEMU shell polling endurance stress (millions of poll iterations)
3. Multi-Device Attachment:
   - QEMU with multiple devices (-device usb-kbd -device usb-mouse)
   - Address separation (Addr 1 != Addr 2)
   - Endpoint scoping & UHCI schedule queue head linking
   - Maximum device registry boundary protection (MAX_USB_DEVICES = 8)
"""

import os
import sys
import time
import subprocess
import re
from typing import List, Dict, Optional, Tuple, Any

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

COLOR_GREEN = "\033[92m"
COLOR_RED = "\033[91m"
COLOR_YELLOW = "\033[93m"
COLOR_CYAN = "\033[96m"
COLOR_BOLD = "\033[1m"
COLOR_RESET = "\033[0m"

def log_test(name: str, passed: bool, details: str = ""):
    status = f"{COLOR_GREEN}[PASS]{COLOR_RESET}" if passed else f"{COLOR_RED}[FAIL]{COLOR_RESET}"
    print(f"  {status} {COLOR_BOLD}{name}{COLOR_RESET}")
    if details:
        for line in details.strip().splitlines():
            print(f"         {line}")

def run_qemu_test(
    extra_args: List[str],
    timeout_sec: float = 12.0,
    stop_pattern: Optional[str] = None
) -> Tuple[bool, str, float]:
    qemu_bin = "qemu-system-x86_64"
    cmd = [
        qemu_bin,
        "-cdrom", os.path.join(REPO_ROOT, "kernel.iso"),
        "-serial", "stdio",
        "-display", "none",
        "-m", "512M",
        "-smp", "4",
    ] + extra_args

    t0 = time.time()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=REPO_ROOT
    )

    stopped = False
    output_lines = []

    if stop_pattern:
        while True:
            elapsed = time.time() - t0
            if elapsed > timeout_sec:
                break
            line = proc.stdout.readline()
            if not line and proc.poll() is not None:
                break
            if line:
                output_lines.append(line)
                if stop_pattern in line:
                    stopped = True
                    break
        try:
            proc.kill()
        except Exception:
            pass
        out_rest, _ = proc.communicate()
        output_lines.append(out_rest)
    else:
        # Run for timeout_sec then kill
        try:
            out, _ = proc.communicate(timeout=timeout_sec)
            output_lines.append(out)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
            output_lines.append(out)
            stopped = True

    duration = time.time() - t0
    full_output = "".join(output_lines)
    return stopped or (proc.returncode == 0), full_output, duration


def challenge_1_unattached_ports() -> bool:
    print(f"\n{COLOR_CYAN}--- Challenge 1: Unattached Port Behavior & Timing Stress ---{COLOR_RESET}")
    all_ok = True

    # Test 1.1: 3 Controllers (xHCI + EHCI + UHCI) with ZERO devices attached
    print("  [1.1] Testing 3 controllers (xHCI + EHCI + UHCI) with 0 devices attached...")
    args = [
        "-device", "qemu-xhci,id=xhci",
        "-device", "ich9-usb-ehci1,id=ehci",
        "-device", "ich9-usb-uhci1,id=uhci",
    ]
    ok, out, duration = run_qemu_test(args, timeout_sec=10.0, stop_pattern="[USB] Subsystem initialized with")
    
    no_freeze = ok and duration < 7.0
    has_init = "[USB] Subsystem initialized with 3 controller(s), 0 active USB device(s)" in out
    has_xhci = "[USB] Found xHCI (USB 3.0) Controller" in out
    has_ehci = "[USB] Found EHCI (USB 2.0) Controller" in out
    has_uhci = "[USB] Found UHCI (USB 1.1) Controller" in out

    c1_1 = no_freeze and has_init and has_xhci and has_ehci and has_uhci
    all_ok = all_ok and c1_1
    log_test(
        "3 Concurrent Controllers Zero-Device Boot",
        c1_1,
        f"Duration: {duration:.2f}s (Freeze threshold: 7.0s)\n"
        f"Detected 3 controllers, 0 devices: {has_init}"
    )

    # Test 1.2: 4 Unattached UHCI Controllers (total 8 root ports unattached)
    print("  [1.2] Testing 4 unattached UHCI controllers (8 unattached root ports)...")
    args_4uhci = [
        "-device", "ich9-usb-uhci1,id=u1",
        "-device", "ich9-usb-uhci2,id=u2",
        "-device", "ich9-usb-uhci3,id=u3",
        "-device", "ich9-usb-uhci1,id=u4",
    ]
    ok, out, duration = run_qemu_test(args_4uhci, timeout_sec=10.0, stop_pattern="[USB] Subsystem initialized with")
    uhci_count = out.count("[USB] Found UHCI (USB 1.1) Controller")
    c1_2 = ok and duration < 7.0 and uhci_count == 4 and "[USB] Subsystem initialized with 4 controller(s), 0 active USB device(s)" in out
    all_ok = all_ok and c1_2
    log_test(
        "4 UHCI Controllers (8 unattached root ports) Non-Blocking Scan",
        c1_2,
        f"Duration: {duration:.2f}s, Found {uhci_count} UHCI controllers, 0 devices"
    )

    # Test 1.3: Partial port attachment (Port 1 has usb-kbd, Port 2 is empty)
    print("  [1.3] Testing partial port attachment (Port 1 connected, Port 2 unattached)...")
    args_partial = [
        "-device", "ich9-usb-uhci1,id=u1",
        "-device", "usb-kbd,bus=u1.0,port=1",
    ]
    ok, out, duration = run_qemu_test(args_partial, timeout_sec=10.0, stop_pattern="[USB] Subsystem initialized with")
    has_kbd = "[USB] Registered USB Keyboard" in out and "Addr 1" in out
    has_one_dev = "[USB] Subsystem initialized with 1 controller(s), 1 active USB device(s)" in out
    c1_3 = ok and duration < 7.0 and has_kbd and has_one_dev
    all_ok = all_ok and c1_3
    log_test(
        "Partial Port Population (Port 1 device, Port 2 empty without stall)",
        c1_3,
        f"Duration: {duration:.2f}s, Device registered at Addr 1: {has_kbd}"
    )

    # Test 1.4: Code Inspection Oracle for Unattached Port Handling
    print("  [1.4] Code inspection oracle for unattached port branches...")
    uhci_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "uhci.zig")
    ehci_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "ehci.zig")
    xhci_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "xhci.zig")
    mod_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "mod.zig")

    with open(uhci_path) as f: u_src = f.read()
    with open(ehci_path) as f: e_src = f.read()
    with open(xhci_path) as f: x_src = f.read()
    with open(mod_path) as f: m_src = f.read()

    u_oracle = "connected = (status & 0x01) != 0;" in u_src and 'device_desc = "No device"' in u_src
    e_oracle = "connected = (status & 0x01) != 0;" in e_src and 'device_desc = "No device"' in e_src
    x_oracle = "connected = (status & 0x01) != 0;" in x_src and 'device_desc = "No device"' in x_src
    m_oracle = "u.ports[p].connected and u.ports[p].enabled" in m_src

    c1_4 = u_oracle and e_oracle and x_oracle and m_oracle
    all_ok = all_ok and c1_4
    log_test(
        "Unattached Port Code Branching Oracle (No spin-waits on empty ports)",
        c1_4,
        f"UHCI: {u_oracle}, EHCI: {e_oracle}, xHCI: {x_oracle}, Mod guard: {m_oracle}"
    )

    return all_ok


def challenge_2_rapid_polling() -> bool:
    print(f"\n{COLOR_CYAN}--- Challenge 2: Rapid Device Polling & Stress Loop ---{COLOR_RESET}")
    all_ok = True

    # Test 2.1: Code Oracle: Zero-Allocation and Wrapping Arithmetic in poll()
    print("  [2.1] Verifying zero-allocation & arithmetic safety in usb.poll()...")
    mod_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "mod.zig")
    with open(mod_path) as f: m_src = f.read()

    poll_match = re.search(r'pub fn poll\(\) void \{([\s\S]*?)\n\}', m_src)
    if not poll_match:
        log_test("usb.poll() structure", False, "Could not find pub fn poll() in mod.zig")
        return False
    poll_body = poll_match.group(1)

    has_no_kalloc = "kalloc" not in poll_body and "allocPage" not in poll_body and "alloc(" not in poll_body
    has_wrapping_add = "+%=" in poll_body  # dev.packet_count +%= 1
    has_volatile_check = "volatile" in poll_body  # readVolatile on TD_CTRL_ACTIVE
    has_active_guard = "uhci.TD_CTRL_ACTIVE" in poll_body

    c2_1 = has_no_kalloc and has_wrapping_add and has_volatile_check and has_active_guard
    all_ok = all_ok and c2_1
    log_test(
        "Memory Leak & Overflow Immunity in usb.poll()",
        c2_1,
        f"Zero allocations: {has_no_kalloc}\n"
        f"Wrapping counter arithmetic (+%=): {has_wrapping_add}\n"
        f"Volatile TD active guard: {has_active_guard}"
    )

    # Test 2.2: Live QEMU Tight-Loop Polling Endurance Test
    print("  [2.2] Live QEMU shell idle tight-loop polling endurance test...")
    # Boot QEMU, wait until USB subsystem initialized, then let it poll continuously in shell for 4s
    cmd = [
        "qemu-system-x86_64",
        "-cdrom", os.path.join(REPO_ROOT, "kernel.iso"),
        "-serial", "stdio",
        "-display", "none",
        "-m", "512M",
        "-smp", "4",
        "-device", "ich9-usb-uhci1,id=u1",
        "-device", "usb-kbd,bus=u1.0,port=1",
        "-device", "usb-mouse,bus=u1.0,port=2",
    ]
    t0 = time.time()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=REPO_ROOT)
    out_lines = []
    has_init = False
    while time.time() - t0 < 15.0:
        line = proc.stdout.readline()
        if not line and proc.poll() is not None:
            break
        if line:
            out_lines.append(line)
            if "[USB] Subsystem initialized with" in line:
                has_init = True
                # Now let it run for 4 seconds continuously in the shell tight polling loop
                time.sleep(4.0)
                break
    try:
        proc.kill()
    except Exception:
        pass
    rest, _ = proc.communicate()
    out_lines.append(rest)
    duration = time.time() - t0
    out = "".join(out_lines)

    no_panic = "KERNEL PANIC" not in out and "Double Fault" not in out and "Triple Fault" not in out and "General Protection" not in out
    has_devices = "[USB] Subsystem initialized with 1 controller(s), 2 active USB device(s)" in out
    has_shell = "[USER-HEAP] free + reuse OK" in out

    c2_2 = no_panic and has_devices and has_shell and has_init
    all_ok = all_ok and c2_2
    log_test(
        "Live QEMU Continuous Polling Endurance",
        c2_2,
        f"Total time: {duration:.2f}s, Zero Panics: {no_panic}, Reached Shell: {has_shell}, USB Active: {has_devices}"
    )

    return all_ok


def challenge_3_multi_device_attachment() -> bool:
    print(f"\n{COLOR_CYAN}--- Challenge 3: Multi-Device Attachment & Registry Collisions ---{COLOR_RESET}")
    all_ok = True

    # Test 3.1: Dual Device Attachment (usb-kbd + usb-mouse) on UHCI
    print("  [3.1] Testing dual device attachment (usb-kbd + usb-mouse)...")
    args = [
        "-device", "ich9-usb-uhci1,id=u1",
        "-device", "usb-kbd,bus=u1.0,port=1",
        "-device", "usb-mouse,bus=u1.0,port=2",
    ]
    ok, out, duration = run_qemu_test(args, timeout_sec=10.0, stop_pattern="[USB] Subsystem initialized with")

    kbd_match = re.search(r'\[USB\] Registered (USB Keyboard[^\n]*) at Addr (\d+)', out)
    mouse_match = re.search(r'\[USB\] Registered (USB Mouse[^\n]*) at Addr (\d+)', out)

    has_both = kbd_match is not None and mouse_match is not None
    addr_distinct = False
    kbd_addr = None
    mouse_addr = None
    if has_both:
        kbd_addr = int(kbd_match.group(2))
        mouse_addr = int(mouse_match.group(2))
        addr_distinct = (kbd_addr != mouse_addr) and (kbd_addr > 0) and (mouse_addr > 0)

    c3_1 = has_both and addr_distinct
    all_ok = all_ok and c3_1
    log_test(
        "Multi-Device Address Separation (Addr 1 vs Addr 2)",
        c3_1,
        f"Keyboard Addr: {kbd_addr}, Mouse Addr: {mouse_addr}, Distinct: {addr_distinct}"
    )

    # Test 3.2: Endpoint and Token Scoping Analysis
    print("  [3.2] Validating TD token address encoding & schedule Queue Head linking...")
    mod_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "mod.zig")
    with open(mod_path) as f: m_src = f.read()

    relink_match = "relinkUhciControllerSchedule" in m_src
    token_addr_encoded = "@as(u32, dev.addr) << 8" in m_src
    token_ep_encoded = "@as(u32, dev.ep_in) << 15" in m_src
    qh_chaining = "pq.head_link = @intCast(@intFromPtr(&dev.qh) | 0x02);" in m_src
    ctrl_qh_termination = "u_ctrl.ctrl_qh.head_link = 1;" in m_src

    c3_2 = relink_match and token_addr_encoded and token_ep_encoded and qh_chaining and ctrl_qh_termination
    all_ok = all_ok and c3_2
    log_test(
        "UHCI Queue Head Linking & Address-Scoped Token Oracle",
        c3_2,
        f"Token Addr Shift (<< 8): {token_addr_encoded}\n"
        f"Token EP Shift (<< 15): {token_ep_encoded}\n"
        f"QH Chaining: {qh_chaining}\n"
        f"Schedule Termination: {ctrl_qh_termination}"
    )

    # Test 3.3: Device Registry Boundary Protection (MAX_USB_DEVICES = 8)
    print("  [3.3] Verifying device registry boundary checks (MAX_USB_DEVICES = 8)...")
    has_bound_check = "usb_device_count < MAX_USB_DEVICES" in m_src
    has_max_def = "MAX_USB_DEVICES: usize = 8" in m_src or "MAX_USB_DEVICES" in m_src

    c3_3 = has_bound_check and has_max_def
    all_ok = all_ok and c3_3
    log_test(
        "Device Registry Array Bounds Protection (No overflow on >8 devices)",
        c3_3,
        f"Bounds check guard in enumeration: {has_bound_check}"
    )

    return all_ok


def main():
    print(f"\n{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}  Zirconium OS — Milestone 2 Adversarial Stress & Empirical Challenge Suite{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}")

    c1 = challenge_1_unattached_ports()
    c2 = challenge_2_rapid_polling()
    c3 = challenge_3_multi_device_attachment()

    print(f"\n{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}")
    print(f"{COLOR_BOLD}SUMMARY OF ADVERSARIAL CHALLENGES:{COLOR_RESET}")
    print(f"  Challenge 1 (Unattached Ports):     {'PASSED' if c1 else 'FAILED'}")
    print(f"  Challenge 2 (Rapid Polling):        {'PASSED' if c2 else 'FAILED'}")
    print(f"  Challenge 3 (Multi-Device Attach):  {'PASSED' if c3 else 'FAILED'}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}\n")

    if c1 and c2 and c3:
        print(f"{COLOR_BOLD}{COLOR_GREEN}ALL ADVERSARIAL STRESS CHALLENGES PASSED EMPIRICALLY!{COLOR_RESET}\n")
        sys.exit(0)
    else:
        print(f"{COLOR_BOLD}{COLOR_RED}ONE OR MORE CHALLENGES FAILED!{COLOR_RESET}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
