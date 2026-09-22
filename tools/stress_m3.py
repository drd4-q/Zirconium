#!/usr/bin/env python3
"""
Zirconium OS — Milestone 3 Adversarial Stress & Empirical Challenge Suite.
Empirical Challenger 2 (challenger_m3_2).

Challenges Tested:
1. Key Rollover & Rapid Report Decoding:
   - 6-Key Rollover (6KRO) simultaneous keypresses in a single report
   - Rollover error codes (0x01 ErrorRollOver, 0x02 POSTFail) ignored safely
   - Key release and press tracking via prev_report
   - Direct key ring buffer capacity (63 unread items) and circular wrap-around
   - Rapid sequence endurance (10,000 rapid report decodes without dropped chars)
   - Live QEMU boot and USB keyboard registration
2. Corrupted or Truncated HID Reports:
   - Truncated keyboard reports (lengths 0..7 bytes)
   - Truncated mouse reports (lengths 0..2 bytes)
   - Report-ID prefixed report length boundary checks
   - Exhaustive Usage ID safety (all 256 byte values x 8 modifier combinations)
   - Fuzzing stress (50,000 random-length random-byte payloads with zero panics)
   - Slice bounds and out-of-bounds immunity inspection
3. Continuous Mouse Motion & Coordinate Clamping:
   - Framebuffer mode clamping (0..1023, 0..767)
   - Text console mode clamping (0..79, 0..24)
   - Continuous motion stress (100,000 steps with random deltas in [-128, 127])
   - Extreme large delta clamping (+/-100,000,000) without integer overflow
   - Live QEMU boot and USB mouse registration
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

def run_zig_stress_binary() -> Tuple[bool, str]:
    """Compile and execute the native Zig HID stress harness with runtime safety checks enabled."""
    cmd = ["zig", "run", os.path.join(REPO_ROOT, "tools", "test_hid_stress.zig")]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=REPO_ROOT, timeout=30.0)
        output = res.stdout + res.stderr
        return (res.returncode == 0), output
    except Exception as e:
        return False, str(e)

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


def challenge_1_key_rollover_and_decoding(zig_ok: bool, zig_out: str) -> bool:
    print(f"\n{COLOR_CYAN}--- Challenge 1: Key Rollover & Rapid Report Decoding ---{COLOR_RESET}")
    all_ok = True

    # 1.1: Assert 6KRO and error code rejection from native Zig test
    c1_1 = "[PASS] 1.1: 6-Key Rollover" in zig_out and "[PASS] 1.2: USB HID rollover error codes" in zig_out
    all_ok = all_ok and c1_1
    log_test(
        "6-Key Rollover (6KRO) & Rollover Error Rejection (0x01, 0x02)",
        c1_1,
        "Native Zig test verified 6 simultaneous keypresses decoded in exact order and rollover error codes ignored"
    )

    # 1.2: Assert ring buffer capacity and circular wrap-around
    c1_2 = "[PASS] 1.4: Direct key ring buffer capacity" in zig_out and "[PASS] 1.5: 10,000 rapid report" in zig_out
    all_ok = all_ok and c1_2
    log_test(
        "Direct Key Ring Buffer Bounds & Rapid Sequence Endurance",
        c1_2,
        "Verified 63-item capacity limit, graceful drop on overflow, and 10,000 rapid report decodes without dropped keys"
    )

    # 1.3: Code Oracle: Ring Buffer & Rollover Logic
    print("  [1.3] Code inspection oracle for keyboard ring buffer & rollover tracking...")
    kb_path = os.path.join(REPO_ROOT, "src", "drivers", "keyboard.zig")
    hid_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "hid.zig")

    with open(kb_path) as f: kb_src = f.read()
    with open(hid_path) as f: hid_src = f.read()

    has_ring_size = "KEY_BUF_SIZE: usize = 64;" in kb_src
    has_modulo_wrap = "(direct_key_head + 1) % KEY_BUF_SIZE;" in kb_src
    has_overflow_guard = "if (next != direct_key_tail)" in kb_src
    has_kro_loop = "while (k < 8) : (k += 1)" in hid_src
    has_prev_check = "if (prev_report[prev_k] == key)" in hid_src

    c1_3 = has_ring_size and has_modulo_wrap and has_overflow_guard and has_kro_loop and has_prev_check
    all_ok = all_ok and c1_3
    log_test(
        "Ring Buffer Capacity & 6KRO Tracking Code Oracle",
        c1_3,
        f"KEY_BUF_SIZE=64: {has_ring_size}, Modulo wrap: {has_modulo_wrap}, Overflow guard: {has_overflow_guard}, 6KRO loop: {has_kro_loop}"
    )

    # 1.4: Live QEMU Boot with USB Keyboard
    print("  [1.4] Live QEMU boot test with USB keyboard...")
    args = [
        "-device", "ich9-usb-uhci1,id=u1",
        "-device", "usb-kbd,bus=u1.0,port=1",
    ]
    ok, out, duration = run_qemu_test(args, timeout_sec=10.0, stop_pattern="[USB] Subsystem initialized with")
    has_kbd_reg = "[USB] Registered USB Keyboard (HID Boot) at Addr 1" in out
    c1_4 = ok and has_kbd_reg
    all_ok = all_ok and c1_4
    log_test(
        "Live QEMU USB Keyboard Enumeration & Scheduling",
        c1_4,
        f"Duration: {duration:.2f}s, USB Keyboard registered: {has_kbd_reg}"
    )

    return all_ok


def challenge_2_corrupted_and_truncated_reports(zig_ok: bool, zig_out: str) -> bool:
    print(f"\n{COLOR_CYAN}--- Challenge 2: Corrupted or Truncated HID Reports ---{COLOR_RESET}")
    all_ok = True

    # 2.1: Assert truncated report rejections from native Zig test
    c2_1 = "[PASS] 2.1: Truncated keyboard reports" in zig_out and "[PASS] 2.4: Truncated mouse reports" in zig_out
    all_ok = all_ok and c2_1
    log_test(
        "Truncated Packet Length Rejection (Keyboard 0..7B, Mouse 0..2B)",
        c2_1,
        "Native Zig test verified early returns on truncated packets without slice index errors"
    )

    # 2.2: Assert exhaustive usage ID check & random fuzzer results
    c2_2 = "[PASS] 2.6: Exhaustive 256 usage IDs" in zig_out and "[PASS] 2.7: 50,000 fuzzing iterations" in zig_out
    all_ok = all_ok and c2_2
    log_test(
        "Exhaustive Usage ID Safety & Fuzzing Immunity (50,000 Random Packets)",
        c2_2,
        "Verified all 256 byte usage IDs across 8 modifier permutations and 50,000 fuzzed packets with ZERO panics"
    )

    # 2.3: Code Oracle: Bounds & Slice Guards in hid.zig
    print("  [2.3] Code inspection oracle for report bounds checks...")
    hid_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "hid.zig")
    with open(hid_path) as f: hid_src = f.read()

    has_kbd_len_guard = "if (report.len < 8) return;" in hid_src
    has_kbd_offset_guard = "if (report.len < offset + 8) return;" in hid_src
    has_mouse_len_guard = "if (report.len < 3) return;" in hid_src
    has_mouse_offset_guard = "if (report.len < offset + 3) return;" in hid_src
    has_prev_copy_min = "const copy_len = @min(prev_report.len, 8);" in hid_src
    has_usage_else_null = "else => return null," in hid_src

    c2_3 = has_kbd_len_guard and has_kbd_offset_guard and has_mouse_len_guard and has_mouse_offset_guard and has_prev_copy_min and has_usage_else_null
    all_ok = all_ok and c2_3
    log_test(
        "HID Report Slicing & Memory Bounds Oracle",
        c2_3,
        f"Kbd len guard: {has_kbd_len_guard}, Mouse len guard: {has_mouse_len_guard}, Prev copy clamp: {has_prev_copy_min}, Usage else null: {has_usage_else_null}"
    )

    return all_ok


def challenge_3_mouse_motion_and_coordinate_clamping(zig_ok: bool, zig_out: str) -> bool:
    print(f"\n{COLOR_CYAN}--- Challenge 3: Continuous Mouse Motion & Coordinate Clamping ---{COLOR_RESET}")
    all_ok = True

    # 3.1: Assert coordinate clamping and continuous motion from native Zig test
    c3_1 = "[PASS] 3.1: Framebuffer mode coordinate clamping" in zig_out and "[PASS] 3.2: Text console mode" in zig_out
    all_ok = all_ok and c3_1
    log_test(
        "Screen Coordinate Clamping (0..1023, 0..767 & 0..79, 0..24)",
        c3_1,
        "Native Zig test verified boundary clamping in both graphical framebuffer and VGA text modes"
    )

    # 3.2: Continuous Motion & Extreme Delta Updates
    c3_2 = "[PASS] 3.3: 100,000 continuous mouse motion steps" in zig_out and "[PASS] 3.4: Extreme +/-100M delta updates" in zig_out
    all_ok = all_ok and c3_2
    log_test(
        "Continuous Motion Endurance & Extreme Delta Overflow Immunity",
        c3_2,
        "100,000 steps verified strictly within bounds; extreme +/-100M delta additions clamped without integer overflow"
    )

    # 3.3: Code Oracle: Mouse Clamping & Delta Casting
    print("  [3.3] Code inspection oracle for mouse coordinate clamping & delta casting...")
    mouse_path = os.path.join(REPO_ROOT, "src", "drivers", "mouse.zig")
    hid_path = os.path.join(REPO_ROOT, "src", "drivers", "usb", "hid.zig")

    with open(mouse_path) as f: mouse_src = f.read()
    with open(hid_path) as f: hid_src = f.read()

    has_fb_clamp = "if (mx >= @as(i32, @intCast(fb.fb_width))) mx = @as(i32, @intCast(fb.fb_width)) - 1;" in mouse_src
    has_text_clamp = "if (mx >= 80) mx = 79;" in mouse_src
    has_usb_clamp_call = "clampCoords();" in mouse_src
    has_i8_cast = "@as(i32, @as(i8, @bitCast(report[offset + 1])))" in hid_src

    c3_3 = has_fb_clamp and has_text_clamp and has_usb_clamp_call and has_i8_cast
    all_ok = all_ok and c3_3
    log_test(
        "Coordinate Clamping & Signed Delta Casting Code Oracle",
        c3_3,
        f"FB clamp: {has_fb_clamp}, Text clamp: {has_text_clamp}, Clamp call: {has_usb_clamp_call}, i8 bitCast: {has_i8_cast}"
    )

    # 3.4: Live QEMU Boot with USB Mouse
    print("  [3.4] Live QEMU boot test with USB mouse...")
    args = [
        "-device", "ich9-usb-uhci1,id=u1",
        "-device", "usb-mouse,bus=u1.0,port=1",
    ]
    ok, out, duration = run_qemu_test(args, timeout_sec=10.0, stop_pattern="[USB] Subsystem initialized with")
    has_mouse_reg = "[USB] Registered USB Mouse (HID Boot) at Addr 1" in out
    c3_4 = ok and has_mouse_reg
    all_ok = all_ok and c3_4
    log_test(
        "Live QEMU USB Mouse Enumeration & Scheduling",
        c3_4,
        f"Duration: {duration:.2f}s, USB Mouse registered: {has_mouse_reg}"
    )

    return all_ok


def main():
    print(f"{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}  Zirconium OS — Milestone 3 Empirical Stress & Adversarial Challenge Suite{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}\n")

    print("[STEP 1] Running Native Zig HID Stress Harness (runtime safety enabled)...")
    zig_ok, zig_out = run_zig_stress_binary()
    if not zig_ok:
        print(f"{COLOR_RED}[ERROR] Native Zig stress harness failed:{COLOR_RESET}\n{zig_out}")
        sys.exit(1)
    print(f"{COLOR_GREEN}[SUCCESS] Native Zig stress harness executed cleanly (100% SUCCESS){COLOR_RESET}")

    c1_ok = challenge_1_key_rollover_and_decoding(zig_ok, zig_out)
    c2_ok = challenge_2_corrupted_and_truncated_reports(zig_ok, zig_out)
    c3_ok = challenge_3_mouse_motion_and_coordinate_clamping(zig_ok, zig_out)

    all_passed = c1_ok and c2_ok and c3_ok

    print(f"\n{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}")
    if all_passed:
        print(f"{COLOR_BOLD}{COLOR_GREEN}  ALL ADVERSARIAL CHALLENGES PASSED EMPIRICALLY (100% SUCCESS){COLOR_RESET}")
    else:
        print(f"{COLOR_BOLD}{COLOR_RED}  ONE OR MORE ADVERSARIAL CHALLENGES FAILED{COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_CYAN}{'='*80}{COLOR_RESET}\n")

    sys.exit(0 if all_passed else 1)

if __name__ == "__main__":
    main()
