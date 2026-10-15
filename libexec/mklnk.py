"""Write a Windows shortcut (.lnk) without Windows' COM API.

sh-tafeta writes desktop shortcuts from WSL as plain files in the documented Shell Link
format ([MS-SHLLINK]). Creating them through PowerShell's WScript.Shell is what
antivirus software (Bitdefender, at least) blocks as persistence behaviour.

Only what a shortcut to a local program needs: LinkInfo with the local path,
description, arguments, icon, show command.

usage: python3 mklnk.py OUT.lnk TARGET_EXE ARGUMENTS ICON_PATH ICON_INDEX SHOW(1|7) DESCRIPTION
"""

import struct
import sys
import uuid


def _string(s):
    data = s.encode("utf-16-le")
    return struct.pack("<H", len(data) // 2) + data


def build(target, arguments, icon_path, icon_index=0, show=1, description=""):
    # HasLinkInfo HasName HasArguments HasIconLocation IsUnicode HasExpString
    flags = 0x02 | 0x04 | 0x20 | 0x40 | 0x80 | 0x200
    header = struct.pack(
        "<I16sIIQQQIiIHHII",
        0x4C,
        uuid.UUID("00021401-0000-0000-c000-000000000046").bytes_le,
        flags,
        0x20,            # FILE_ATTRIBUTE_ARCHIVE
        0, 0, 0,         # creation / access / write time
        0,               # file size
        icon_index,
        show,            # 1 = normal, 7 = minimized
        0, 0, 0, 0,      # hotkey, reserved
    )

    volume = struct.pack("<IIII", 0x11, 3, 0, 0x10) + b"\x00"   # fixed drive, empty label
    base = target.encode("mbcs" if sys.platform == "win32" else "latin-1") + b"\x00"
    header_size = 0x1C
    vol_off = header_size
    base_off = vol_off + len(volume)
    suffix_off = base_off + len(base)
    body = volume + base + b"\x00"
    link_info = struct.pack("<IIIIIII", header_size + len(body), header_size, 0x1,
                            vol_off, base_off, 0, suffix_off) + body

    strings = _string(description) + _string(arguments) + _string(icon_path)

    # EnvironmentVariableDataBlock: the target as an expandable path. This is what the
    # shell resolves when the link has no item ID list.
    exp = target
    win = "C:\\Windows"
    if exp.lower().startswith(win.lower()):
        exp = "%windir%" + exp[len(win):]
    ansi = exp.encode("latin-1")[:259].ljust(260, b"\x00")
    wide = exp.encode("utf-16-le")[:518].ljust(520, b"\x00")
    env_block = struct.pack("<II", 0x314, 0xA0000001) + ansi + wide

    return header + link_info + strings + env_block + b"\x00\x00\x00\x00"


if __name__ == "__main__":
    out, target, args, icon, idx, show, desc = sys.argv[1:8]
    data = build(target, args, icon, int(idx), int(show), desc)
    with open(out, "wb") as f:
        f.write(data)
