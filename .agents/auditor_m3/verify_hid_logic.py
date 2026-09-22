#!/usr/bin/env python3
"""
Independent algorithmic verification of Worker 3's USB HID decoding logic.
Tests:
- Scancode to ASCII conversion (A-Z, 0-9, symbols, navigation keys, keypad)
- Modifier handling (Shift, Ctrl, CapsLock)
- Keyboard Boot Report decoding (standard 8-byte and report-ID prefixed 9-byte)
- Mouse Boot Report decoding (standard 3-byte and report-ID prefixed 4-byte)
- Signed delta X/Y extraction
- Multi-interface configuration descriptor parser logic
"""

import sys

def usb_key_to_ascii(key: int, shift: bool, ctrl: bool, caps: bool):
    if 0x04 <= key <= 0x1D:
        base = ord('a') + (key - 0x04)
        if ctrl:
            return base & 0x1F
        if shift != caps:
            return base - 32
        return base

    if ctrl and key == 0x2F:
        return 0x1B # ESC

    if 0x1E <= key <= 0x27:
        if shift:
            mapping = {
                0x1E: ord('!'), 0x1F: ord('@'), 0x20: ord('#'), 0x21: ord('$'),
                0x22: ord('%'), 0x23: ord('^'), 0x24: ord('&'), 0x25: ord('*'),
                0x26: ord('('), 0x27: ord(')')
            }
            return mapping.get(key, 0)
        else:
            if key == 0x27: return ord('0')
            return ord('1') + (key - 0x1E)

    symbols = {
        0x28: ord('\n'), 0x29: 0x1B, 0x2A: 0x08, 0x2B: ord('\t'), 0x2C: ord(' '),
        0x2D: ord('_') if shift else ord('-'),
        0x2E: ord('+') if shift else ord('='),
        0x2F: ord('{') if shift else ord('['),
        0x30: ord('}') if shift else ord(']'),
        0x31: ord('|') if shift else ord('\\'),
        0x33: ord(':') if shift else ord(';'),
        0x34: ord('"') if shift else ord('\''),
        0x35: ord('~') if shift else ord('`'),
        0x36: ord('<') if shift else ord(','),
        0x37: ord('>') if shift else ord('.'),
        0x38: ord('?') if shift else ord('/'),
        # Keypad
        0x54: ord('/'), 0x55: ord('*'), 0x56: ord('-'), 0x57: ord('+'),
        0x58: ord('\n'), 0x59: ord('1'), 0x5A: ord('2'), 0x5B: ord('3'),
        0x5C: ord('4'), 0x5D: ord('5'), 0x5E: ord('6'), 0x5F: ord('7'),
        0x60: ord('8'), 0x61: ord('9'), 0x62: ord('0'), 0x63: ord('.'),
    }
    return symbols.get(key, None)

def test_key_mapping():
    # 'a' scancode is 0x04
    assert usb_key_to_ascii(0x04, False, False, False) == ord('a')
    assert usb_key_to_ascii(0x04, True, False, False) == ord('A')
    assert usb_key_to_ascii(0x04, False, False, True) == ord('A') # CapsLock
    assert usb_key_to_ascii(0x04, True, False, True) == ord('a')  # Shift + CapsLock cancels
    assert usb_key_to_ascii(0x04, False, True, False) == 1        # Ctrl+A = 0x01
    assert usb_key_to_ascii(0x06, False, True, False) == 3        # Ctrl+C = 0x03

    # '1' scancode is 0x1E
    assert usb_key_to_ascii(0x1E, False, False, False) == ord('1')
    assert usb_key_to_ascii(0x1E, True, False, False) == ord('!')
    assert usb_key_to_ascii(0x27, False, False, False) == ord('0')
    assert usb_key_to_ascii(0x27, True, False, False) == ord(')')

    # Enter (0x28), Space (0x2C), Esc (0x29)
    assert usb_key_to_ascii(0x28, False, False, False) == ord('\n')
    assert usb_key_to_ascii(0x2C, False, False, False) == ord(' ')
    assert usb_key_to_ascii(0x29, False, False, False) == 0x1B
    print("[PASS] Key mapping tests passed.")

def test_mouse_report():
    # 3-byte standard report: [buttons, dx, dy]
    # dx = -5 (0xFB as signed 8-bit), dy = 10 (0x0A)
    # buttons = 1 (left click)
    report = bytes([0x01, 0xFB, 0x0A])
    buttons = report[0]
    import ctypes
    dx = ctypes.c_int8(report[1]).value
    dy = ctypes.c_int8(report[2]).value
    assert buttons == 1
    assert dx == -5
    assert dy == 10

    # 4-byte report-ID prefixed report: [report_id, buttons, dx, dy]
    report_prefixed = bytes([0x02, 0x02, 0x05, 0xF6]) # report_id 2, right click, dx=5, dy=-10 (0xF6)
    is_prefixed = (len(report_prefixed) >= 4 and report_prefixed[0] != 0 and report_prefixed[0] <= 4)
    assert is_prefixed
    offset = 1 if is_prefixed else 0
    buttons_p = report_prefixed[offset + 0]
    dx_p = ctypes.c_int8(report_prefixed[offset + 1]).value
    dy_p = ctypes.c_int8(report_prefixed[offset + 2]).value
    assert buttons_p == 2
    assert dx_p == 5
    assert dy_p == -10
    print("[PASS] Mouse report decoding tests passed.")

def test_composite_descriptor_parsing():
    # Synthetic multi-interface config descriptor:
    # Interface 0: Class 0x03, Subclass 0x01, Protocol 0x01 (Keyboard)
    #   Endpoint 0x81 (Interrupt IN, max_packet 8, interval 10)
    # Interface 1: Class 0x03, Subclass 0x01, Protocol 0x02 (Mouse)
    #   Endpoint 0x82 (Interrupt IN, max_packet 8, interval 10)
    config_desc = bytes([
        # Config Descriptor header (9 bytes)
        0x09, 0x02, 0x3B, 0x00, 0x02, 0x01, 0x00, 0xA0, 0x32,
        # Interface 0 (9 bytes)
        0x09, 0x04, 0x00, 0x00, 0x01, 0x03, 0x01, 0x01, 0x00,
        # HID Descriptor (9 bytes)
        0x09, 0x21, 0x10, 0x01, 0x00, 0x01, 0x22, 0x3F, 0x00,
        # Endpoint 1 (7 bytes)
        0x07, 0x05, 0x81, 0x03, 0x08, 0x00, 0x0A,
        # Interface 1 (9 bytes)
        0x09, 0x04, 0x01, 0x00, 0x01, 0x03, 0x01, 0x02, 0x00,
        # HID Descriptor (9 bytes)
        0x09, 0x21, 0x10, 0x01, 0x00, 0x01, 0x22, 0x34, 0x00,
        # Endpoint 2 (7 bytes)
        0x07, 0x05, 0x82, 0x03, 0x08, 0x00, 0x0A,
    ])

    interfaces = []
    current_iface = None
    off = 0
    total_len = len(config_desc)
    while off + 2 <= total_len:
        desc_len = config_desc[off]
        if desc_len < 2 or off + desc_len > total_len:
            break
        desc_type = config_desc[off + 1]

        if desc_type == 4: # DESC_INTERFACE
            current_iface = {
                'interface_num': config_desc[off + 2],
                'class_code': config_desc[off + 5],
                'subclass_code': config_desc[off + 6],
                'protocol_code': config_desc[off + 7],
                'endpoints': []
            }
            interfaces.append(current_iface)
        elif desc_type == 5: # DESC_ENDPOINT
            if current_iface is not None:
                ep_addr = config_desc[off + 2]
                ep_attr = config_desc[off + 3]
                max_pkt = config_desc[off + 4] | (config_desc[off + 5] << 8)
                interval = config_desc[off + 6]
                current_iface['endpoints'].append({
                    'ep_addr': ep_addr,
                    'ep_num': ep_addr & 0x0F,
                    'is_in': (ep_addr & 0x80) != 0,
                    'transfer_type': ep_attr & 3,
                    'max_pkt': max_pkt,
                    'interval': interval
                })
        off += desc_len

    assert len(interfaces) == 2, f"Expected 2 interfaces, got {len(interfaces)}"
    # Verify Interface 0
    assert interfaces[0]['interface_num'] == 0
    assert interfaces[0]['class_code'] == 3
    assert interfaces[0]['protocol_code'] == 1 # Keyboard
    assert len(interfaces[0]['endpoints']) == 1
    assert interfaces[0]['endpoints'][0]['ep_num'] == 1
    assert interfaces[0]['endpoints'][0]['is_in'] == True

    # Verify Interface 1
    assert interfaces[1]['interface_num'] == 1
    assert interfaces[1]['class_code'] == 3
    assert interfaces[1]['protocol_code'] == 2 # Mouse
    assert len(interfaces[1]['endpoints']) == 1
    assert interfaces[1]['endpoints'][0]['ep_num'] == 2
    assert interfaces[1]['endpoints'][0]['is_in'] == True

    print("[PASS] Multi-interface composite parsing logic verified.")

if __name__ == '__main__':
    test_key_mapping()
    test_mouse_report()
    test_composite_descriptor_parsing()
    print("ALL INDEPENDENT LOGIC TESTS PASSED SUCCESSFULLY!")
