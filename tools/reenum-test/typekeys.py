#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""Type text into a guest over QMP send-key (QWERTY or Dvorak guests).

  python typekeys.py --port P [--dvorak] 'text'    (\\n = Enter, \\t = Tab)
  python typekeys.py --port P key ctrl-esc          (one chord, '-' joined)
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "scripts"))
from qmp import QMP  # noqa: E402

# physical US key qcode -> (unshifted char, shifted char)
QW = {"grave_accent": "`~", "minus": "-_", "equal": "=+",
      "bracket_left": "[{", "bracket_right": "]}", "backslash": "\\|",
      "semicolon": ";:", "apostrophe": "'\"", "comma": ",<", "dot": ".>",
      "slash": "/?", "spc": "  "}
for c in "abcdefghijklmnopqrstuvwxyz":
    QW[c] = c + c.upper()
for d, s in zip("1234567890", "!@#$%^&*()"):
    QW[d] = d + s
# US Dvorak: what each physical key produces
DV = dict(QW)
DV.update({"q": "'\"", "w": ",<", "e": ".>", "r": "pP", "t": "yY",
           "y": "fF", "u": "gG", "i": "cC", "o": "rR", "p": "lL",
           "bracket_left": "/?", "bracket_right": "=+", "a": "aA",
           "s": "oO", "d": "eE", "f": "uU", "g": "iI", "h": "dD",
           "j": "hH", "k": "tT", "l": "nN", "semicolon": "sS",
           "apostrophe": "-_", "z": ";:", "x": "qQ", "c": "jJ", "v": "kK",
           "b": "xX", "n": "bB", "m": "mM", "comma": "wW", "dot": "vV",
           "slash": "zZ", "minus": "[{", "equal": "]}"})


def keys_for(ch, layout):
    if ch == "\n":
        return ["ret"]
    if ch == "\t":
        return ["tab"]
    for k, (lo, hi) in layout.items():
        if ch == lo:
            return [k]
        if ch == hi:
            return ["shift", k]
    raise ValueError("no key for %r" % ch)


def main():
    argv = sys.argv[1:]
    port = 47800
    layout = QW
    while argv and argv[0].startswith("--"):
        if argv[0] == "--port":
            port = int(argv[1])
            argv = argv[2:]
        elif argv[0] == "--dvorak":
            layout = DV
            argv = argv[1:]
    q = QMP(port)
    if argv[0] == "key":
        for chord in argv[1:]:
            q.cmd("send-key", {"keys": [{"type": "qcode", "data": k}
                                        for k in chord.split("-")]})
            time.sleep(0.15)
    else:
        text = argv[0].replace("\\n", "\n").replace("\\t", "\t")
        for ch in text:
            q.cmd("send-key", {"keys": [{"type": "qcode", "data": k}
                                        for k in keys_for(ch, layout)]})
            time.sleep(0.06)
    q.close()


if __name__ == "__main__":
    main()
