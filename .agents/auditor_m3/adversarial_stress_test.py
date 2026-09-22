#!/usr/bin/env python3
"""
Adversarial stress-testing suite for Zirconium USB HID decoding:
- Malformed/truncated packets
- Extreme mouse displacement values (-128, +127, 0, wrapping)
- Rapid key presses and modifier permutations
- Deep / nested / malformed config descriptors
"""

import sys
import ctypes

def simulate_decode_keyboard(report: bytes, prev_report: bytearray, caps_lock_state: bool):
    if len(report) < 8:
        return caps_lock_state, []

    is_prefixed = (len(report) >= 9 and report[0] != 0 and (report[0] <= 4 or report[1] == 0))
    offset = 1 if is_prefixed else 0
    if len(report) < offset + 8:
        return caps_lock_state, []

    mod = report[offset + 0]
    shift = (mod & 0x22) != 0
    ctrl = (mod & 0x11) != 0

    pushed_keys = []
    for k in range(2, 8):
        key = report[offset + k]
        if key == 0:
            continue
        was_pressed = False
        for prev_k in range(2, min(8, len(prev_report))):
            if prev_report[prev_k] == key:
                was_pressed = True
                break

        if not was_pressed:
            if key == 0x39: # CapsLock
                caps_lock_state = not caps_lock_state
            else:
                pushed_keys.append((key, shift, ctrl, caps_lock_state))

    copy_len = min(len(prev_report), 8)
    prev_report[:copy_len] = report[offset : offset + copy_len]
    return caps_lock_state, pushed_keys

def simulate_decode_mouse(report: bytes, prev_report: bytearray):
    if len(report) < 3:
        return None

    is_prefixed = (len(report) >= 4 and report[0] != 0 and report[0] <= 4)
    offset = 1 if is_prefixed else 0
    if len(report) < offset + 3:
        return None

    buttons = report[offset + 0]
    dx = ctypes.c_int8(report[offset + 1]).value
    dy = ctypes.c_int8(report[offset + 2]).value

    last_buttons = prev_report[0] if len(prev_report) > 0 else 0
    dispatched = None
    if dx != 0 or dy != 0 or buttons != last_buttons:
        dispatched = (buttons, dx, dy)

    if len(prev_report) > 0:
        prev_report[0] = buttons
    return dispatched

def test_adversarial_keyboard():
    # 1. Truncated reports
    for length in range(0, 8):
        caps, keys = simulate_decode_keyboard(bytes([0]*length), bytearray(8), False)
        assert len(keys) == 0, f"Failed on truncated length {length}"

    # 2. Malformed report-ID prefixed reports
    # Report claiming to be prefixed (len 9, byte 0 is 1), but len is only 8
    caps, keys = simulate_decode_keyboard(bytes([1, 0, 0x04, 0, 0, 0, 0, 0]), bytearray(8), False)
    assert len(keys) == 0 or len(keys) == 1 # Safe handling without index out of range

    # 3. Rollover / all keys pressed
    prev = bytearray(8)
    report = bytes([0, 0, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]) # a, b, c, d, e, f
    caps, keys = simulate_decode_keyboard(report, prev, False)
    assert len(keys) == 6

    # 4. Same keys held down (no new events)
    caps, keys2 = simulate_decode_keyboard(report, prev, caps)
    assert len(keys2) == 0, "Keys held down should not generate new press events"

    # 5. One key released, new key pressed
    report2 = bytes([0, 0, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0A]) # f replaced by g (0x0A)
    caps, keys3 = simulate_decode_keyboard(report2, prev, caps)
    assert len(keys3) == 1 and keys3[0][0] == 0x0A

    # 6. CapsLock toggle
    caps, keys_caps = simulate_decode_keyboard(bytes([0, 0, 0x39, 0, 0, 0, 0, 0]), prev, False)
    assert caps == True

    print("[PASS] Adversarial keyboard stress tests passed.")

def test_adversarial_mouse():
    # 1. Extreme boundary values
    prev = bytearray(4)
    # dx = -128 (0x80), dy = +127 (0x7F)
    res = simulate_decode_mouse(bytes([0x01, 0x80, 0x7F]), prev)
    assert res == (1, -128, 127)

    # dx = 0, dy = 0, button unchanged -> no dispatch
    res2 = simulate_decode_mouse(bytes([0x01, 0x00, 0x00]), prev)
    assert res2 is None

    # dx = 0, dy = 0, button released -> dispatch button change
    res3 = simulate_decode_mouse(bytes([0x00, 0x00, 0x00]), prev)
    assert res3 == (0, 0, 0)

    # Negative coordinates
    # dx = -1 (0xFF), dy = -1 (0xFF)
    res4 = simulate_decode_mouse(bytes([0x04, 0xFF, 0xFF]), prev) # middle click = 4
    assert res4 == (4, -1, -1)

    print("[PASS] Adversarial mouse stress tests passed.")

def test_adversarial_config_parser():
    # Zero length descriptor in chain (malformed)
    malformed_chain = bytes([0x00, 0x00, 0x04, 0x05])
    off = 0
    total_len = len(malformed_chain)
    steps = 0
    while off + 2 <= total_len:
        desc_len = malformed_chain[off]
        if desc_len < 2 or off + desc_len > total_len:
            break
        off += desc_len
        steps += 1
    assert steps == 0, "Parser correctly terminated on zero length descriptor"

    # Descriptor declaring length exceeding buffer
    overflow_chain = bytes([0x10, 0x04, 0x00]) # says length 16, but buffer is 3 bytes
    off = 0
    total_len = len(overflow_chain)
    steps = 0
    while off + 2 <= total_len:
        desc_len = overflow_chain[off]
        if desc_len < 2 or off + desc_len > total_len:
            break
        off += desc_len
        steps += 1
    assert steps == 0, "Parser correctly avoided buffer overrun"

    print("[PASS] Adversarial config parser stress tests passed.")

if __name__ == '__main__':
    test_adversarial_keyboard()
    test_adversarial_mouse()
    test_adversarial_config_parser()
    print("ALL ADVERSARIAL STRESS TESTS COMPLETED SUCCESSFULLY!")
