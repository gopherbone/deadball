#!/usr/bin/env python3
"""Run a game on a USB-attached Playdate and stream its console over serial.

Lines matching --show are printed as they arrive. When a line matches --until, the
device is switched to data-disk mode right away (before it can auto-lock and drop off
USB), and the script exits.

  python3 -I playdate/tools/serial_run.py /dev/cu.usbmodemPD... /Games/deadball.pdx \
      --until "[tour] done" --timeout 600
Stdlib only (termios), no pyserial.
"""
import argparse, os, select, sys, termios, time


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                 # iflag
    attrs[1] = 0                                 # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0                                 # lflag: raw
    attrs[4] = attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def send(fd, cmd):
    os.write(fd, (cmd + "\n").encode())
    time.sleep(0.2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port")
    ap.add_argument("pdx")
    ap.add_argument("--until", default="[tour] done")
    ap.add_argument("--show", default="[perf]|[bcload]|[bcpup]|[bcspike]|[tour]|ERROR|error")
    ap.add_argument("--timeout", type=float, default=600)
    a = ap.parse_args()
    show = a.show.split("|")
    fd = open_port(a.port)
    send(fd, "echo on")
    send(fd, "run " + a.pdx)
    buf, end, done = b"", time.time() + a.timeout, False
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 1.0)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break  # the port went away (device locked or crashed)
        if not chunk:
            continue
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            text = line.decode("utf-8", "replace").rstrip("\r")
            if any(s in text for s in show):
                print(text, flush=True)
            if a.until in text:
                done = True
                break
        if done:
            break
    if done:
        send(fd, "datadisk")
    os.close(fd)
    print("[serial_run] " + ("done; switched to data disk" if done else "timed out or port lost"), flush=True)
    return 0 if done else 1


if __name__ == "__main__":
    sys.exit(main())
