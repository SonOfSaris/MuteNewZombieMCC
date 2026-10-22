#!/usr/bin/env python3
"""Mute (or restore) the "New Zombie" announcer line in Halo 3 Infection, Halo: The Master Chief
Collection on PC.

Halo 3 keeps its sounds in halo3/fmod/pc/sfx.fsb. This script finds every language's
multiplayer_<language>/infection/new_zombie sound in YOUR copy of that file and rewrites only that
sound's audio data so it plays as silence of the same length. Nothing else in the file changes, and
the file keeps its size. No game files ship with this script.

Before changing anything it saves the original bytes of each muted sound in a "backup" folder next
to this script, so --restore can put them back. Steam's "Verify integrity of game files" also
restores the original file. The backups are the same format as MuteNewZombie.ps1's.

  python3 mute_new_zombie.py                  mute (finds the game through your Steam libraries)
  python3 mute_new_zombie.py --restore        put the original sound back
  python3 mute_new_zombie.py --check          show whether each language is muted
  python3 mute_new_zombie.py --lang en        only these languages (cht de en fr it jpn kor mx pt sp)
  python3 mute_new_zombie.py "<game folder>"  the game folder, its halo3/fmod/pc folder, or sfx.fsb

Python 3.8 or newer, standard library only. MIT licensed.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import struct
import sys

VERSION = "1.0.0"
SOUND_NAME = b"new_zombie"
MCC = "Halo The Master Chief Collection"
BANK_PARTS = ("halo3", "fmod", "pc", "sfx.fsb")
# Halo 3's two Vorbis setups (the CRC32 FMOD stores per sound): stereo, mono. Both have two modes:
# mode 0 = short block, mode 1 = long block.
KNOWN_SETUPS = (0xAD11D38D, 0x632B1FAC)
SOURCE_RE = re.compile(r"\\multiplayer_([a-z]+)\\infection\\new_zombie\.aif$")
HERE = os.path.dirname(os.path.abspath(__file__))
BACKUP_DIR = os.path.join(HERE, "backup")


class Problem(Exception):
    pass


def say(text):
    try:
        print(text, flush=True)
    except (OSError, ValueError):  # closed console or pipe: keep going, the work matters more
        pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# --- finding the game -----------------------------------------------------------------------------

def steam_roots():
    roots = []
    if os.name == "nt":
        try:
            import winreg
            for hive, key, value in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                                     (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                                     (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath")):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        roots.append(str(winreg.QueryValueEx(k, value)[0]).replace("/", "\\"))
                except OSError:
                    pass
        except ImportError:
            pass
        roots.append(r"C:\Program Files (x86)\Steam")
    else:
        home = os.path.expanduser("~")
        for rel in (".steam/steam", ".steam/root", ".local/share/Steam", ".var/app/com.valvesoftware.Steam/.local/share/Steam"):
            roots.append(os.path.join(home, rel))
    return roots


def find_bank(given):
    if given:
        given = given.strip().strip('"')
        for p in (given, os.path.join(given, "sfx.fsb"), os.path.join(given, *BANK_PARTS),
                  os.path.join(given, *BANK_PARTS[1:]), os.path.join(given, "Content", *BANK_PARTS)):
            if os.path.isfile(p) and os.path.basename(p).lower() == "sfx.fsb":
                return os.path.abspath(p)
        raise Problem(f"No halo3/fmod/pc/sfx.fsb found at: {given}")
    libraries = []
    for root in steam_roots():
        libraries.append(root)
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        if os.path.isfile(vdf):
            try:
                text = open(vdf, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            libraries += [m.replace("\\\\", "\\") for m in re.findall(r'"path"\s+"([^"]+)"', text)]
    seen = set()
    for lib in libraries:
        if lib in seen:
            continue
        seen.add(lib)
        p = os.path.join(lib, "steamapps", "common", MCC, *BANK_PARTS)
        if os.path.isfile(p):
            return p
    if os.name == "nt":
        import string
        for letter in string.ascii_uppercase:
            p = os.path.join(f"{letter}:\\", "XboxGames", MCC, "Content", *BANK_PARTS)
            if os.path.isfile(p):
                return p
    raise Problem("Couldn't find Halo: The Master Chief Collection. Run the script again with the game folder, for example:\n"
                  f'  python3 mute_new_zombie.py "D:\\SteamLibrary\\steamapps\\common\\{MCC}"')


# --- reading the sound bank -----------------------------------------------------------------------

def read_targets(bank):
    """Every New Zombie sound: index, language, where its data sits, its Vorbis setup CRC."""
    info = bank + ".info"
    if not os.path.isfile(info):
        raise Problem(f"Missing {info} (needed to tell the languages apart).")
    with open(bank, "rb") as f:
        head = f.read(0x3C)
        if len(head) < 0x3C or head[:4] != b"FSB5":
            raise Problem(f"{bank} is not an FMOD FSB5 sound bank.")
        ver, count, sh_size, name_size, data_size, codec = struct.unpack_from("<6I", head, 4)
        if ver != 1 or codec != 15:
            raise Problem(f"Unexpected sound bank format (FSB5 version {ver}, codec {codec}); expected version 1, Vorbis (15).")
        if name_size == 0:
            raise Problem("The sound bank has no name table.")
        sh = f.read(sh_size)
        names = f.read(name_size)
        if len(sh) != sh_size or len(names) != name_size:
            raise Problem("The sound bank is truncated.")
        f.seek(0, 2)
        file_size = f.tell()
    data_start = 0x3C + sh_size + name_size
    info_bytes = open(info, "rb").read()
    if len(info_bytes) != 280 * count:
        raise Problem(f"{info} doesn't match the sound bank ({len(info_bytes)} bytes for {count} sounds).")
    offsets, crcs, pos = [], [], 0
    for _ in range(count):
        mode, = struct.unpack_from("<Q", sh, pos)
        pos += 8
        offsets.append(((mode >> 7) & 0x07FFFFFF) << 5)
        crc, more = None, mode & 1
        while more:
            c, = struct.unpack_from("<I", sh, pos)
            pos += 4
            more, size, kind = c & 1, (c >> 1) & 0xFFFFFF, (c >> 25) & 0x7F
            if kind == 11 and size >= 4:
                crc, = struct.unpack_from("<I", sh, pos)
            pos += size
        crcs.append(crc)
    want = SOUND_NAME + b"\0"
    targets = []
    for i in range(count):
        o, = struct.unpack_from("<I", names, 4 * i)
        if names[o:o + len(want)] != want:
            continue
        source = info_bytes[280 * i + 0x18: 280 * (i + 1)].split(b"\0", 1)[0].decode("latin-1")
        m = SOURCE_RE.search(source)
        if not m:
            continue
        end = offsets[i + 1] if i + 1 < count else data_size
        targets.append({"index": i, "lang": m.group(1), "source": source, "offset": data_start + offsets[i],
                        "length": end - offsets[i], "crc": crcs[i]})
    return file_size, targets


def muted_slot(slot, crc):
    """The muted form of a sound's data: every Vorbis audio packet keeps its size and position and its
    header bits (packet type, mode, and on long blocks the two window flags); every bit after them is
    zeroed, which marks each channel unused, so the packet decodes to silence."""
    if crc not in KNOWN_SETUPS:
        raise Problem(f"Unknown Vorbis setup {crc if crc is None else format(crc, '08x')}; this script only knows Halo 3's.")
    out = bytearray(slot)
    p = packets = 0
    while p + 2 <= len(out):
        size, = struct.unpack_from("<H", out, p)
        if size == 0:
            break
        if p + 2 + size > len(out):
            raise Problem("A sound packet runs past its data; the file may be damaged.")
        first = out[p + 2]
        if first & 1:
            raise Problem("Not a Vorbis audio packet; the file may be damaged or of another version.")
        keep = 0x0F if (first >> 1) & 1 else 0x03
        out[p + 2] = first & keep
        out[p + 3:p + 2 + size] = bytes(size - 1)
        p += 2 + size
        packets += 1
    if not packets:
        raise Problem("No audio packets found.")
    return bytes(out)


# --- writing --------------------------------------------------------------------------------------

def open_exclusive(path):
    """Open for read/write. On Windows, with no sharing, so it fails while the game (or Steam) has the
    file open."""
    if os.name != "nt":
        return open(path, "r+b")
    import ctypes
    import msvcrt
    from ctypes import wintypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                     wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    GENERIC_READ, GENERIC_WRITE, OPEN_EXISTING = 0x80000000, 0x40000000, 3
    handle = kernel32.CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None)
    if handle in (None, wintypes.HANDLE(-1).value):
        err = ctypes.get_last_error()
        if err == 32:
            raise Problem("Can't write to the sound bank: another program has it open. Close the game and try again.")
        if err == 5:
            raise Problem("Can't write to the sound bank: access denied. Close the game; if it's installed under "
                          "Program Files, run this as administrator.")
        raise Problem(f"Can't open the sound bank for writing ({ctypes.WinError(err)}).")
    fd = msvcrt.open_osfhandle(handle, os.O_RDWR | getattr(os, "O_BINARY", 0))
    return os.fdopen(fd, "r+b")


def backup_paths(t):
    base = os.path.join(BACKUP_DIR, f"new_zombie_{t['lang']}")
    return base + ".json", base + ".bin"


def pause_if_double_clicked():
    """Keep the window open when the script was started by double-clicking it on Windows."""
    if os.name != "nt" or not sys.stdin or not sys.stdin.isatty():
        return
    try:
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        pids = (wintypes.DWORD * 16)()
        n = kernel32.GetConsoleProcessList(pids, 16)
        names = []
        for pid in pids[:n]:
            h = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
            if not h:
                return
            buf = ctypes.create_unicode_buffer(1024)
            size = wintypes.DWORD(1024)
            ok = kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
            kernel32.CloseHandle(h)
            if not ok:
                return
            names.append(os.path.basename(buf.value).lower())
        # alone in its console (only python / the py launcher): nobody else will keep the window open
        if names and all(re.match(r"^(py|pyw|python[0-9.]*w?)\.exe$", n) for n in names):
            input("\nPress Enter to close...")
    except Exception:  # noqa: BLE001  (a nicety only)
        pass


def main():
    ap = argparse.ArgumentParser(description="Mute (or restore) the New Zombie announcer in Halo 3 (MCC, PC).")
    ap.add_argument("path", nargs="?", help="the game folder, its halo3/fmod/pc folder, or sfx.fsb (default: find it through Steam)")
    ap.add_argument("--restore", action="store_true", help="put the original sound back from this script's backup")
    ap.add_argument("--check", action="store_true", help="only report whether each language is muted")
    ap.add_argument("--lang", help="only these languages, comma-separated: cht de en fr it jpn kor mx pt sp")
    args = ap.parse_args()

    say(f"New Zombie mute {VERSION} (Python)")
    bank = find_bank(args.path)
    say(f"Sound bank: {bank}")
    file_size, targets = read_targets(bank)
    if args.lang:
        wanted = [x.strip().lower() for x in args.lang.split(",") if x.strip()]
        available = [t["lang"] for t in targets]
        unknown = [x for x in wanted if x not in available]
        if unknown:
            raise Problem(f"Unknown language(s): {', '.join(unknown)}. Available: {' '.join(available)}")
        targets = [t for t in targets if t["lang"] in wanted]
    if not targets:
        raise Problem("No New Zombie sound found in this sound bank.")

    with open(bank, "rb") as f:
        for t in targets:
            f.seek(t["offset"])
            t["current"] = f.read(t["length"])
            t["muted"] = muted_slot(t["current"], t["crc"])
            t["current_sha"], t["muted_sha"] = sha256(t["current"]), sha256(t["muted"])

    if args.check:
        for t in targets:
            say(f"  {t['lang']:<4} {'muted' if t['current_sha'] == t['muted_sha'] else 'original (not muted)'}")
        return 0

    writes = []
    if not args.restore:
        for t in targets:
            if t["current_sha"] == t["muted_sha"]:
                say(f"  {t['lang']:<4} already muted")
            else:
                writes.append((t, t["muted"], t["muted_sha"], "muted"))
        if writes:
            os.makedirs(BACKUP_DIR, exist_ok=True)
            for t, _data, _sha, _done in writes:
                jpath, bpath = backup_paths(t)
                with open(bpath, "wb") as f:
                    f.write(t["current"])
                meta = {"script_version": VERSION, "bank": bank, "bank_size": file_size, "index": t["index"], "source": t["source"],
                        "offset": t["offset"], "length": t["length"], "original_sha256": t["current_sha"],
                        "muted_sha256": t["muted_sha"], "saved": datetime.datetime.now().replace(microsecond=0).isoformat()}
                with open(jpath, "w", encoding="utf-8") as f:
                    json.dump(meta, f, indent=4)
                if sha256(open(bpath, "rb").read()) != t["current_sha"]:
                    raise Problem(f"The backup {bpath} didn't save correctly; nothing was changed.")
    else:
        for t in targets:
            jpath, bpath = backup_paths(t)
            if t["current_sha"] != t["muted_sha"]:
                say(f"  {t['lang']:<4} not muted: nothing to restore")
                continue
            if not (os.path.isfile(jpath) and os.path.isfile(bpath)):
                say(f"  {t['lang']:<4} muted, but there's no backup for it here. Use Steam's \"Verify integrity of game files\" to restore it.")
                continue
            try:
                with open(jpath, encoding="utf-8-sig") as f:
                    meta = json.load(f)
            except ValueError:
                meta = {}
            orig = open(bpath, "rb").read()
            if (meta.get("offset") != t["offset"] or meta.get("length") != t["length"] or meta.get("bank_size") != file_size
                    or meta.get("muted_sha256") != t["muted_sha"] or sha256(orig) != meta.get("original_sha256")):
                say(f"  {t['lang']:<4} the backup doesn't match this file (was the game updated?). Use Steam's \"Verify integrity of game files\" instead.")
                continue
            writes.append((t, orig, meta["original_sha256"], "restored"))

    if writes:
        with open_exclusive(bank) as f:
            f.seek(0, 2)
            if f.tell() != file_size:
                raise Problem("The sound bank changed while the script was running; nothing was written.")
            for t, data, _sha, _done in writes:
                f.seek(t["offset"])
                f.write(data)
            f.flush()
            os.fsync(f.fileno())
            for t, _data, sha, done in writes:
                f.seek(t["offset"])
                if sha256(f.read(t["length"])) != sha:
                    raise Problem(f"Verification failed for {t['lang']}; restore with Steam's \"Verify integrity of game files\".")
                say(f"  {t['lang']:<4} {done}")
        if not args.restore:
            say(f"Backup of the original sounds: {BACKUP_DIR}")
    say("Done.")
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except Problem as e:
        say(f"Error: {e}")
        code = 1
    except Exception as e:  # noqa: BLE001
        say(f"Error: {type(e).__name__}: {e} (Python {sys.version.split()[0]})")
        code = 1
    pause_if_double_clicked()
    sys.exit(code)
