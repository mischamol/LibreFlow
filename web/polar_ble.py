"""Polar watch Bluetooth explorer (PSFTP), read-only.

Speaks Polar's PSFTP file protocol over BLE, as implemented in the open-source
Polar BLE SDK (service 0xFEEE, RFC76 framing, PbPFtpOperation requests).

Only GET operations are sent, with two explicit exceptions that each ask you to type WRITE first:
`fav-put` writes one training favorite to a new folder /U/0/FAV/<nn>/, and `zones-put` replaces only the heart-rate
and speed zone limits in the running sport profile (everything else in that file stays byte for byte the same).
Nothing is ever deleted from the watch.

Usage:
  python polar_ble.py scan
  python polar_ble.py services <address>
  python polar_ble.py ls <address> [path]            (default "/")
  python polar_ble.py get <address> <path> [outfile]
  python polar_ble.py pull <address> <path> <outdir> [--depth N]
  python polar_ble.py decode <file>                   (protobuf wire dump of a .BPB/.GZB)
  python polar_ble.py --sync all <address> [outdir] [--since YYYYMMDD] [--max N]   (download every training, resumable)
  python polar_ble.py export [indir] [outdir] [--full]   (downloaded trainings -> training-session-*.json)
  python polar_ble.py --sync fav-put <address> <dir with TST.BPB + ID.BPB> <nn>   (WRITES one favorite; asks first)
  python polar_ble.py --sync zones-put <address> <backup PROFILE.BPB> --hr 50,136,146,156,167,181 --pace 6:03,5:04,4:37,4:16
                       (WRITES the zones of /U/0/SPROF/0/PROFILE.BPB; asks first)   … --restore writes the backup back
(The old Dutch names alles/exporteer/--vanaf/--volledig still work.)
Options: --debug (print raw frames), --pair (ask Windows to pair first)
"""
import argparse
import asyncio
import gzip
import os
import struct
import sys

PFTP_SVC = "0000feee-0000-1000-8000-00805f9b34fb"
MTU_CH = "fb005c51-02e7-f387-1cad-8acd2d8df0c8"   # requests + responses
D2H_CH = "fb005c52-02e7-f387-1cad-8acd2d8df0c8"   # device -> host notifications
H2D_CH = "fb005c53-02e7-f387-1cad-8acd2d8df0c8"   # host -> device notifications (unused)

ERRORS = {103: "file or folder does not exist", 108: "timeout", 202: "system busy"}
DEBUG = False


def log(*a):
    if DEBUG:
        print("  [debug]", *a, file=sys.stderr)


# ---------- minimal protobuf ----------
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def read_varint(buf, i):
    shift = val = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


def pb_fields(buf):
    """Yield (field_no, wire_type, value) for a protobuf message. Raises on malformed data."""
    i = 0
    while i < len(buf):
        key, i = read_varint(buf, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = read_varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]; i += 8
        elif wt == 2:
            ln, i = read_varint(buf, i)
            v = buf[i:i + ln]; i += ln
            if i > len(buf):
                raise ValueError("truncated")
        elif wt == 5:
            v = buf[i:i + 4]; i += 4
        else:
            raise ValueError(f"wire type {wt}")
        if f == 0:
            raise ValueError("field 0")
        yield f, wt, v


def pb_op_put(path):
    p = path.encode()
    return b"\x08" + varint(1) + b"\x12" + varint(len(p)) + p   # PbPFtpOperation{command=PUT, path}


def pb_op_get(path):
    p = path.encode()
    return b"\x08" + varint(0) + b"\x12" + varint(len(p)) + p   # PbPFtpOperation{command=GET, path}


def parse_dir(payload):
    """PbPFtpDirectory { repeated PbPFtpEntry entries = 1 }, entry {name=1, size=2, ...}."""
    entries = []
    for f, wt, v in pb_fields(payload):
        if f == 1 and wt == 2:
            name, size = None, None
            for ef, ewt, ev in pb_fields(v):
                if ef == 1 and ewt == 2:
                    name = ev.decode(errors="replace")
                elif ef == 2 and ewt == 0:
                    size = ev
            entries.append((name, size))
    return entries


def dump(buf, indent=0, max_depth=6):
    pad = "  " * indent
    try:
        fields = list(pb_fields(buf))
    except Exception:
        print(f"{pad}<{len(buf)} bytes raw> {buf[:32].hex()}")
        return
    for f, wt, v in fields:
        if wt == 0:
            print(f"{pad}{f}: {v}")
        elif wt in (1, 5) and len(v) != (8 if wt == 1 else 4):
            print(f"{pad}{f}: <truncated {v.hex()}>")
        elif wt == 1:
            print(f"{pad}{f}: double {struct.unpack('<d', v)[0]:.6f}")
        elif wt == 5:
            print(f"{pad}{f}: float {struct.unpack('<f', v)[0]:.4f} / u32 {struct.unpack('<I', v)[0]}")
        else:
            txt = None
            try:
                t = v.decode()
                if t.isprintable() and len(v) > 0:
                    txt = t
            except UnicodeDecodeError:
                pass
            nested_ok = False
            if indent < max_depth and len(v) > 0:
                try:
                    list(pb_fields(v)); nested_ok = True
                except Exception:
                    pass
            if txt is not None and not nested_ok:
                print(f'{pad}{f}: "{txt}"')
            elif nested_ok:
                print(f"{pad}{f} {{")
                dump(v, indent + 1, max_depth)
                print(f"{pad}}}")
            else:
                print(f"{pad}{f}: <{len(v)} bytes> {v[:24].hex()}{'…' if len(v) > 24 else ''}")


# ---------- PSFTP over BLE ----------
class PftpError(Exception):
    def __init__(self, code):
        super().__init__(f"PSFTP error {code}: {ERRORS.get(code, 'unknown')}")
        self.code = code


class Pftp:
    def __init__(self, client):
        self.c = client
        self.q = asyncio.Queue()
        self.frame = 20

    async def start(self):
        mtu = getattr(self.c, "mtu_size", 23) or 23
        self.frame = max(20, mtu - 3)
        log("MTU", mtu, "frame", self.frame)
        print("  step: enable notifications", file=sys.stderr)
        for attempt in range(3):
            try:
                await self.c.start_notify(MTU_CH, lambda _, d: self.q.put_nowait(bytes(d)))
                break
            except Exception as e:
                print(f"  attempt {attempt + 1} failed ({e}); requesting security again", file=sys.stderr)
                if not self.c.is_connected or attempt == 2:
                    raise
                if not IS_MAC:
                    try:
                        await self.c.pair()   # already bonded: asks Windows to encrypt the link with the stored keys
                    except Exception as pe:
                        log("pair:", pe)
                await asyncio.sleep(1)
        mtu = getattr(self.c, "mtu_size", 23) or 23
        self.frame = max(20, mtu - 3)
        log("MTU na beveiliging", mtu)
        try:
            await self.c.start_notify(D2H_CH, lambda _, d: print(f"  [watch notification] {bytes(d).hex()}", file=sys.stderr))
        except Exception as e:
            log("D2H notify failed:", e)

    def frames(self, data):
        chunk, out, i, seq, nxt = self.frame - 1, [], 0, 0, 0
        while True:
            part = data[i:i + chunk]
            i += len(part)
            more = i < len(data)
            out.append(bytes([(nxt | (0x06 if more else 0x02)) | (seq << 4)]) + part)
            nxt, seq = 1, (seq + 1) & 0x0F
            if not more:
                return out

    async def request(self, header, timeout=30):
        return await self.request_raw(struct.pack("<H", len(header) & 0x7FFF) + header, timeout)

    async def request_raw(self, stream, timeout=30, acked=False):
        while not self.q.empty():
            self.q.get_nowait()
        for f in self.frames(stream):
            log("->", f.hex())
            await self.c.write_gatt_char(MTU_CH, f, response=acked)   # acked: wait for each frame (writes)
        out, exp_seq, n = bytearray(), 0, 0
        while True:
            pkt = await asyncio.wait_for(self.q.get(), timeout)
            h = pkt[0]
            nxt, st, seq = h & 1, (h >> 1) & 3, (h >> 4) & 0x0F
            if n < 3 or DEBUG:
                log(f"<- next={nxt} status={st} seq={seq} len={len(pkt)} {pkt[:16].hex()}")
            n += 1
            if st == 0:
                err = (pkt[1] | (pkt[2] << 8)) if len(pkt) >= 3 else (pkt[1] if len(pkt) > 1 else 0)
                if err == 0:
                    return bytes(out)
                raise PftpError(err)
            if seq != exp_seq:
                await self.c.write_gatt_char(MTU_CH, b"\x00\x00\x00", response=False)
                raise RuntimeError(f"packet lost (expected seq {exp_seq}, got {seq})")
            exp_seq = (seq + 1) & 0x0F
            out += pkt[1:]
            if n % 50 == 0:
                print(f"  … {len(out)} bytes", file=sys.stderr, end="\r")
            if st == 1:
                return bytes(out)
            if st != 3:
                raise RuntimeError(f"unknown status {st}")

    # --- sync session signalling, exactly as Polar BLE SDK's
    #     sendInitializationAndStartSyncNotifications / sendTerminateAndStopSyncNotifications.
    #     These are protocol notifications only; they do not change any file on the watch.
    async def query(self, qid, params=b"", timeout=30):
        return await self.request_raw(bytes([qid & 0xFF, ((qid >> 8) & 0x7F) | 0x80]) + params, timeout)

    async def notify(self, nid, params=b""):
        for f in self.frames(bytes([nid]) + params):
            log("H2D ->", f.hex())
            await self.c.write_gatt_char(H2D_CH, f, response=False)

    async def start_sync(self):
        if os.environ.get("POLAR_REQSYNC") == "1":
            print("  step: REQUEST_SYNCHRONIZATION", file=sys.stderr)
            r = await self.query(13)
            log("antwoord", r.hex())
        print("  step: INITIALIZE_SESSION", file=sys.stderr)
        await self.notify(8)
        print("  step: START_SYNC", file=sys.stderr)
        await self.notify(0)
        print("  sync session started", file=sys.stderr)

    async def stop_sync(self):
        await self.notify(1, b"\x08\x01")   # STOP_SYNC {completed: true}
        await self.notify(9)                # TERMINATE_SESSION
        print("  sync session finished", file=sys.stderr)

    async def put(self, path, data=b"", timeout=60):
        """PUT a file (or, with a path ending in '/' and no data, create a folder), as Polar BLE SDK's
        BlePsFtpClient.write: RFC60 header length + PbPFtpOperation + file data in one RFC76 stream."""
        header = pb_op_put(path)
        return await self.request_raw(struct.pack("<H", len(header) & 0x7FFF) + header + data, timeout, acked=True)

    async def get(self, path, timeout=60):
        return await self.request(pb_op_get(path), timeout)

    async def ls(self, path):
        if not path.endswith("/"):
            path += "/"
        return parse_dir(await self.get(path))


# ---------- commands ----------
async def cmd_scan(_):
    print("Scanning for Bluetooth devices (10 s)…")
    found = await BleakScanner.discover(timeout=10, return_adv=True)
    rows = sorted(found.values(), key=lambda x: -(x[1].rssi or -999))
    polar = [(d, a) for d, a in rows if "polar" in (d.name or a.local_name or "").lower() or "0000feee" in " ".join(a.service_uuids).lower()]
    for d, a in (polar or rows[:15]):
        print(f"{d.address}  {a.rssi:>4} dBm  {d.name or a.local_name or '(no name)'}  services={a.service_uuids}")
    if not polar:
        print("\nNo Polar device seen. Tips: turn off Bluetooth on your phone, wake the watch, or press Sync on it.")


IS_MAC = sys.platform == "darwin"
MAC_RE = __import__("re").compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")


async def find_watch(target, timeout):
    """target: Bluetooth address (Windows/Linux), CoreBluetooth UUID (macOS) or part of the name, e.g. 'Grit X'."""
    if MAC_RE.match(target) or (IS_MAC and len(target) == 36 and target.count("-") == 4):
        return await BleakScanner.find_device_by_address(target, timeout=timeout)
    t = target.lower()
    return await BleakScanner.find_device_by_filter(
        lambda d, a: t in (d.name or a.local_name or "").lower(), timeout=timeout)


async def connect_mac(args):
    # macOS / iOS (CoreBluetooth): no explicit pair/unpair API. The OS pairs and re-encrypts
    # by itself the first time an encrypted characteristic is used (a pairing dialog may appear).
    print("Waiting for the watch (max 3 min; pairing mode, or press Sync on the watch)…", file=sys.stderr)
    dev = await find_watch(args.address, 180)
    if not dev:
        sys.exit("Watch not seen. Press Sync on the watch or put it in pairing mode.")
    print(f"Connecting to {dev.name} ({dev.address})…", file=sys.stderr)
    c = BleakClient(dev, timeout=30)
    await c.connect()
    return c


async def connect(args):
    if IS_MAC:
        return await connect_mac(args)
    c = None
    if not args.pair and MAC_RE.match(args.address):
        # bonded watch: Windows can connect directly, no advertising needed
        print(f"Connecting directly to {args.address}…", file=sys.stderr)
        c = BleakClient(args.address, timeout=60)
        try:
            await c.connect()
        except Exception as e:
            log("direct connect failed:", e)
            c = None
    if c is None:
        print("Waiting for the watch (max 3 min; press Sync on the watch)…", file=sys.stderr)
        dev = await find_watch(args.address, 180)
        if not dev:
            sys.exit("Watch not seen. Press Sync on the watch or put it in pairing mode.")
        print(f"Connecting to {args.address}…", file=sys.stderr)
        c = BleakClient(dev, timeout=30)
        await c.connect()
    if args.pair and os.environ.get("POLAR_NOUNPAIR") == "1":
        print("Pairing (confirm on the watch / in Windows if asked)…", file=sys.stderr)
        await c.pair()
    elif args.pair:
        try:
            await c.unpair()   # drop a stale Windows bond the watch no longer knows
            await c.disconnect()
            c = BleakClient(await find_watch(args.address, 60) or args.address, timeout=30)
            await c.connect()
        except Exception as e:
            log("unpair:", e)
        print("Pairing (confirm on the watch / in Windows if asked)…", file=sys.stderr)
        await c.pair()
    return c


async def cmd_services(args):
    c = await connect(args)
    try:
        print(f"Connected. MTU={getattr(c, 'mtu_size', '?')}")
        for s in c.services:
            print(f"[service] {s.uuid}  {s.description}")
            for ch in s.characteristics:
                print(f"    {ch.uuid}  {','.join(ch.properties)}  {ch.description}")
        print("\nPSFTP service (FEEE) present:", any(s.uuid.lower() == PFTP_SVC for s in c.services))
    finally:
        await c.disconnect()


async def with_pftp(args, fn):
    c = await connect(args)
    try:
        p = Pftp(c)
        await p.start()
        if args.sync:
            await p.start_sync()
        result = await fn(p)
        if args.sync:
            await p.stop_sync()
            await asyncio.sleep(1)   # let the last writes leave before disconnecting
        return result
    finally:
        await c.disconnect()


async def cmd_ls(args):
    async def run(p):
        entries = await p.ls(args.path)
        print(f"{args.path}  ({len(entries)} items)")
        for name, size in entries:
            print(f"  {name:<32} {'' if name.endswith('/') else size}")
    await with_pftp(args, run)


async def cmd_get(args):
    async def run(p):
        data = await p.get(args.path, timeout=120)
        out = args.outfile or os.path.basename(args.path.rstrip("/")) or "out.bin"
        with open(out, "wb") as f:
            f.write(data)
        print(f"{len(data)} bytes -> {out}")
    await with_pftp(args, run)


async def cmd_fav_put(args):
    """Write ONE training favorite (TST.BPB + ID.BPB) into a new folder /U/0/FAV/<nn>/. Refuses existing folders,
    other paths and anything but those two files, and asks you to type WRITE first."""
    slot = args.slot
    if not (len(slot) == 2 and slot.isdigit()):
        sys.exit("slot must be two digits, e.g. 02")
    files = []
    for name in ("TST.BPB", "ID.BPB"):
        fp = os.path.join(args.dir, name)
        if not os.path.isfile(fp):
            sys.exit(f"missing {fp}")
        with open(fp, "rb") as f:
            data = f.read()
        if not 0 < len(data) <= 4096:
            sys.exit(f"{fp}: unexpected size {len(data)}")
        files.append((name, data))
    folder = f"/U/0/FAV/{slot}/"

    async def run(p):
        existing = [n for n, _ in await p.ls("/U/0/FAV/")]
        print("/U/0/FAV/ now:", " ".join(existing) or "(empty)")
        if f"{slot}/" in existing:
            print(f"{folder} already exists: nothing written.")
            return
        print("About to WRITE to the watch:")
        print(f"  create folder {folder}")
        for name, data in files:
            print(f"  {folder}{name}  ({len(data)} bytes)")
        if input("Type WRITE to continue: ").strip() != "WRITE":
            print("Cancelled: nothing written.")
            return
        await p.put(folder)
        for name, data in files:
            await p.put(folder + name, data)
            print(f"  written {folder}{name}")
        print(f"{folder} now:", " ".join(f"{n} {s}" for n, s in await p.ls(folder)))
    await with_pftp(args, run)


# ---------- sport profile zones (zones-put) ----------
def pb_split(b):
    """[(field, raw bytes of the whole field, value or payload)] in original order (varint / length / fixed only)"""
    i, out = 0, []
    while i < len(b):
        start = i
        k, i = read_varint(b, i)
        f, t = k >> 3, k & 7
        if t == 0:
            v, i = read_varint(b, i)
        elif t == 2:
            n, i = read_varint(b, i); v = b[i:i + n]; i += n
        elif t == 5:
            v = b[i:i + 4]; i += 4
        elif t == 1:
            v = b[i:i + 8]; i += 8
        else:
            raise ValueError(f"unsupported wire type {t} at byte {start}")
        out.append((f, b[start:i], v))
    return out


def pb_ld(f, payload):
    return varint(f << 3 | 2) + varint(len(payload)) + payload


def profile_info(b):
    """sport id, heart-rate zones [(lo, hi)] and speed zones [(lo, hi)] km/h of a PbSportProfile"""
    sport = next(v for f, _, v in pb_split(next(v for f, _, v in pb_split(b) if f == 2)) if f == 1)
    st = next(v for f, _, v in pb_split(b) if f == 3)
    zl = next(v for f, _, v in pb_split(st) if f == 6)
    hr, sp = [], []
    for f, _, v in pb_split(zl):
        if f in (1, 2):
            d = {ff: vv for ff, _, vv in pb_split(v)}
            hr.append((d[1], d[2])) if f == 1 else sp.append((struct.unpack("<f", d[1])[0], struct.unpack("<f", d[2])[0]))
    return sport, hr, sp


def profile_with_zones(b, hr, sp):
    """Same profile with new zone limits: settings(3) › zone_limits(6) › heart_rate_zone(1) / speed_zone(2) are
    replaced in place; every other field (and the order of fields) is copied byte for byte."""
    def zl_new(zl):
        out, put_hr, put_sp = b"", False, False
        for f, raw, v in pb_split(zl):
            if f == 1:
                if not put_hr:
                    out += b"".join(pb_ld(1, b"\x08" + varint(lo) + b"\x10" + varint(hi)) for lo, hi in hr); put_hr = True
            elif f == 2:
                if not put_sp:
                    out += b"".join(pb_ld(2, b"\x0d" + struct.pack("<f", lo) + b"\x15" + struct.pack("<f", hi)) for lo, hi in sp); put_sp = True
            else:
                out += raw
        return out
    st_new = lambda st: b"".join(pb_ld(6, zl_new(v)) if f == 6 else raw for f, raw, v in pb_split(st))
    return b"".join(pb_ld(3, st_new(v)) if f == 3 else raw for f, raw, v in pb_split(b))


def parse_zone_args(args, cur_hr, cur_sp):
    """--hr: 6 bpm limits; --pace: 4 limits min:sec/km between zones 1|2 … 4|5. Zone 1 starts and zone 5 ends
    where they do now on the watch (so walking still counts as zone 1)."""
    hr = sp = None
    if args.hr:
        v = [int(x) for x in args.hr.split(",")]
        if len(v) != 6 or any(b <= a for a, b in zip(v, v[1:])) or not (30 <= v[0] and v[-1] <= 240):
            sys.exit("--hr needs 6 rising heart rates, e.g. 50,136,146,156,167,181")
        hr = list(zip(v, v[1:]))
    if args.pace:
        secs = []
        for t in args.pace.split(","):
            m, s_ = t.split(":")
            secs.append(int(m) * 60 + int(s_))
        if len(secs) != 4 or any(b >= a for a, b in zip(secs, secs[1:])) or not (120 <= secs[-1] and secs[0] <= 1200):
            sys.exit("--pace needs 4 paces from slow to fast, e.g. 6:03,5:04,4:37,4:16")
        kmh = [cur_sp[0][0]] + [3600 / x for x in secs] + [cur_sp[-1][1]]
        sp = list(zip(kmh, kmh[1:]))
    return hr if hr is not None else cur_hr, sp if sp is not None else cur_sp


def fmt_zones(hr, sp):
    pace = lambda k: "" if k >= 300 else f"{int(60 / k)}:{round(3600 / k % 60):02d}"
    return (["  heart rate: " + "  ".join(f"{a}-{b}" for a, b in hr),
             "  speed km/h: " + "  ".join(f"{a:.2f}-{b:.2f}" for a, b in sp),
             "  pace /km  : " + "  ".join(f"{pace(b) or 'faster'}..{pace(a)}" for a, b in sp)])


async def cmd_zones_put(args):
    """Replace the zones of the running sport profile, or with --restore put the backup back. Reads first, checks
    the file against the backup, shows old and new, asks you to type WRITE, writes, and reads it back."""
    path = f"/U/0/SPROF/{args.slot}/PROFILE.BPB"
    with open(args.backup, "rb") as f:
        backup = f.read()
    sport, b_hr, b_sp = profile_info(backup)
    if sport != 1:
        sys.exit(f"{args.backup} is not the running profile (sport id {sport})")
    if args.restore and (args.hr or args.pace):
        sys.exit("--restore cannot be combined with --hr / --pace")

    async def run(p):
        cur = await p.get(path, timeout=60)
        c_sport, c_hr, c_sp = profile_info(cur)
        if c_sport != 1:
            print(f"{path} is not the running profile (sport id {c_sport}): nothing written."); return
        if args.restore:
            new = backup
        else:
            if cur != backup:
                print(f"{path} differs from {args.backup} (changed on the watch?): nothing written."); return
            hr, sp = parse_zone_args(args, c_hr, c_sp)
            new = profile_with_zones(cur, hr, sp)
            if profile_info(new)[1:] != (hr, [(struct.unpack("<f", struct.pack("<f", a))[0], struct.unpack("<f", struct.pack("<f", b))[0]) for a, b in sp]):
                print("internal check failed: nothing written."); return
        if new == cur:
            print("The watch already has these zones: nothing written."); return
        print(f"{path}  ({len(cur)} -> {len(new)} bytes)")
        print("now on the watch:"); print("\n".join(fmt_zones(c_hr, c_sp)))
        _, n_hr, n_sp = profile_info(new)
        print("after writing:"); print("\n".join(fmt_zones(n_hr, n_sp)))
        if input("Type WRITE to continue: ").strip() != "WRITE":
            print("Cancelled: nothing written."); return
        await p.put(path, new)
        back = await p.get(path, timeout=60)
        print("written and read back:", "identical, OK" if back == new else f"DIFFERENT ({len(back)} bytes) – keep the backup at hand")
    await with_pftp(args, run)


async def cmd_pull(args):
    async def walk(p, path, local, depth):
        os.makedirs(local, exist_ok=True)
        for name, size in await p.ls(path):
            if name.endswith("/"):
                if depth > 0:
                    await walk(p, path.rstrip("/") + "/" + name, os.path.join(local, name.rstrip("/")), depth - 1)
            else:
                target = os.path.join(local, name)
                if os.path.exists(target) and os.path.getsize(target) == size:
                    continue
                data = await p.get(path.rstrip("/") + "/" + name, timeout=300)
                with open(target, "wb") as f:
                    f.write(data)
                print(f"  {path.rstrip('/')}/{name}  {len(data)} bytes")
    await with_pftp(args, lambda p: walk(p, args.path, args.outdir, args.depth))


async def download_dir(p, path, local, depth):
    """Recursively GET every file below path into local. Skips files that already exist with the right size.
    Writes via a .part file so an interrupted download is never mistaken for a complete one."""
    os.makedirs(local, exist_ok=True)
    total = 0
    for name, size in await p.ls(path):
        if name.endswith("/"):
            if depth > 0:
                total += await download_dir(p, path.rstrip("/") + "/" + name, os.path.join(local, name.rstrip("/")), depth - 1)
            continue
        target = os.path.join(local, name)
        if os.path.exists(target) and os.path.getsize(target) == size:
            continue
        data = await p.get(path.rstrip("/") + "/" + name, timeout=300)
        with open(target + ".part", "wb") as f:
            f.write(data)
        os.replace(target + ".part", target)
        total += len(data)
    return total


async def cmd_all(args):
    """Download every training (/U/0/<date>/E/<time>/) since --vanaf, in one connection. Read-only and resumable:
    finished trainings get a .compleet marker, fully checked past days are remembered in index.json
    (marker and key names are kept from the first, Dutch version so existing downloads keep working)."""
    import datetime
    import json
    import time
    root = args.outdir
    os.makedirs(root, exist_ok=True)
    idx_path = os.path.join(root, "index.json")
    idx = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
    checked = set(idx.get("gecontroleerde_dagen", []))
    today = datetime.date.today().strftime("%Y%m%d")

    def save_idx():
        idx["gecontroleerde_dagen"] = sorted(checked)
        with open(idx_path + ".part", "w") as f:
            json.dump(idx, f)
        os.replace(idx_path + ".part", idx_path)

    async def run(p):
        days = sorted(n.rstrip("/") for n, _ in await p.ls("/U/0/") if n.endswith("/") and n[:8].isdigit())
        days = [d for d in days if d >= args.since]
        todo = [d for d in days if d not in checked]
        print(f"{len(days)} days since {args.since}; still to check: {len(todo)}")
        new = nbytes = 0
        t0 = time.time()
        for i, d in enumerate(todo, 1):
            print(f"  [{i}/{len(todo)}] {d}          ", file=sys.stderr, end="\r")
            day_complete = True
            try:
                sub = [n for n, _ in await p.ls(f"/U/0/{d}/")]
                times = [n for n, _ in await p.ls(f"/U/0/{d}/E/")] if "E/" in sub else []
            except PftpError as e:
                print(f"\n  {d}: {e}, skipped")
                continue
            for t in (x.rstrip("/") for x in times if x.endswith("/")):
                local = os.path.join(root, f"{d}_{t}")
                if os.path.exists(os.path.join(local, ".compleet")):
                    continue
                if args.max and new >= args.max:
                    day_complete = False
                    break
                try:
                    nb = await download_dir(p, f"/U/0/{d}/E/{t}/", local, 3)
                except PftpError as e:
                    print(f"\n  {d}/{t}: {e}, skipped (retried next time)")
                    day_complete = False
                    continue
                open(os.path.join(local, ".compleet"), "w").close()
                new += 1
                nbytes += nb
                el = time.time() - t0
                print(f"  {d} {t[:2]}:{t[2:4]}  {nb / 1024:7.0f} kB   (total {new} trainings, "
                      f"{nbytes / 1024 / 1024:.1f} MB, {nbytes / 1024 / max(el, 1):.1f} kB/s)")
            if day_complete and d < today:   # today can still get new trainings
                checked.add(d)
                save_idx()
            if args.max and new >= args.max:
                print(f"\nStopped after --max {args.max}.")
                break
        print(f"\nDone: {new} new trainings, {nbytes / 1024 / 1024:.1f} MB in {time.time() - t0:.0f} s -> {root}/")

    try:
        await with_pftp(args, run)
    except (asyncio.TimeoutError, RuntimeError, OSError) as e:
        save_idx()
        sys.exit(f"\nConnection interrupted ({e}). Starting again continues where it stopped.")


def cmd_export(args):
    """Turn every downloaded training dir into training-session-<date>_<time>.json for libreflow.html."""
    import json
    os.makedirs(args.outdir, exist_ok=True)
    ok = fout = 0   # converted / failed
    for name in sorted(os.listdir(args.indir)):
        d = os.path.join(args.indir, name)
        if not os.path.isfile(os.path.join(d, "00", "BASE.BPB")):
            continue
        try:
            r = decode_training(d)
        except Exception as e:
            print(f"  {name}: could not decode ({e})")
            fout += 1
            continue
        if not args.full:   # keep the 1 s series (for deeper analysis), but leave the GPS route out
            for ex in r["exercises"]:
                ex.pop("route", None)
        extra = sorted(x for x in os.listdir(d) if x.isdigit() and x != "00")
        if extra:
            r["note"] = f"multisport: only part 00 converted (also: {', '.join(extra)})"
        with open(os.path.join(args.outdir, f"training-session-{name}.json"), "w", encoding="utf-8") as f:
            json.dump(r, f)
        ok += 1
    print(f"{ok} trainings converted{f', {fout} errors' if fout else ''} -> {args.outdir}/")
    print("Open libreflow.html › Settings › Choose folder and pick this folder." + ("" if args.full else " (Without GPS route; use --full to include it.)"))


async def cmd_explore(args):
    """One connection: list root, user dir, recent dates, and download the newest exercise."""
    async def run(p):
        async def show(path):
            try:
                e = await p.ls(path)
            except PftpError as err:
                print(f"{path}: {err}")
                return []
            print(f"\n{path}  ({len(e)} items)")
            for name, size in e[:60]:
                print(f"  {name:<32} {'' if name.endswith('/') else size}")
            return e
        await show("/")
        await show("/U/")
        days = sorted(n for n, _ in await show("/U/0/") if n[:8].isdigit())
        newest = None
        for d in reversed(days[-10:]):
            sub = [n for n, _ in await p.ls(f"/U/0/{d}")]
            print(f"  {d} -> {' '.join(sub)}")
            if "E/" in sub and newest is None:
                ex = sorted(n for n, _ in await p.ls(f"/U/0/{d}E/"))
                if ex:
                    newest = f"/U/0/{d}E/{ex[-1]}"
            if newest:
                break
        if not newest:
            print("\nNo training folder found.")
            return
        local = os.path.join(args.outdir, newest.strip("/").replace("/", "_"))
        print(f"\nNewest training: {newest} -> {local}")

        async def walk(path, loc, depth):
            os.makedirs(loc, exist_ok=True)
            for name, size in await p.ls(path):
                if name.endswith("/"):
                    if depth:
                        await walk(path + name, os.path.join(loc, name.rstrip("/")), depth - 1)
                else:
                    data = await p.get(path + name, timeout=300)
                    open(os.path.join(loc, name), "wb").write(data)
                    print(f"  {path}{name}  {len(data)} bytes")
        await walk(newest, local, 3)
    await with_pftp(args, run)


# ---------- training decoding (schemas after cmaion/polar protobufs) ----------
def fields_of(buf, fno):
    return [v for f, _, v in pb_fields(buf) if f == fno]


def one(buf, fno, default=None):
    v = fields_of(buf, fno)
    return v[0] if v else default


def packed_varints(chunks):
    out = []
    for b in chunks:
        if isinstance(b, int):
            out.append(b); continue
        i = 0
        while i < len(b):
            v, i = read_varint(b, i); out.append(v)
    return out


def packed(chunks, fmt):
    size = struct.calcsize(fmt)
    out = []
    for b in chunks:
        if isinstance(b, (bytes, bytearray)):
            n = len(b) // size
            out += struct.unpack("<" + fmt * n, b[:n * size])
    return out


def f32(b):
    return struct.unpack("<f", b)[0] if isinstance(b, (bytes, bytearray)) and len(b) == 4 else None


def pb_duration(b):
    return (one(b, 1, 0) * 3600 + one(b, 2, 0) * 60 + one(b, 3, 0) + one(b, 4, 0) / 1000) if b else 0


def pb_localtime(b):
    d, t = one(b, 1), one(b, 2)
    return (f"{one(d,1):04d}-{one(d,2):02d}-{one(d,3):02d}T"
            f"{one(t,1,0):02d}:{one(t,2,0):02d}:{one(t,3,0):02d}.{one(t,4,0):03d}")


def read_file(path):
    if not os.path.exists(path):
        return None
    data = open(path, "rb").read()
    return gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data


# names as defined by the watch itself (/SYS/SPORT/<id>/SPORT.BPB)
SPORTS = {1: "RUNNING", 2: "CYCLING", 3: "WALKING", 5: "MOUNTAIN_BIKING", 7: "DOWNHILL_SKIING", 11: "HIKING",
          15: "STRENGTH_TRAINING", 16: "OTHER_OUTDOOR", 23: "SWIMMING", 27: "TRAIL_RUNNING", 64: "BODY_AND_MIND",
          82: "MULTISPORT", 83: "OTHER_INDOOR", 126: "CORE", 127: "MOBILITY_STATIC"}


def decode_training(d):
    ex = os.path.join(d, "00")
    base, stats = read_file(os.path.join(ex, "BASE.BPB")), read_file(os.path.join(ex, "STATS.BPB"))
    samples, route = read_file(os.path.join(ex, "SAMPLES.GZB")), read_file(os.path.join(ex, "ROUTE.GZB"))
    start = pb_localtime(one(base, 1))
    tz = one(one(base, 1), 4, 0)
    sec = pb_duration(one(base, 2))
    sport_id = one(one(base, 3), 1, 0)
    dist = f32(one(base, 4)) or 0
    kcal = one(base, 5)
    ascent = f32(one(base, 11))
    rix = one(base, 9)                               # running index computed by the watch: BASE field 9 > 1
    running_index = one(rix, 1) if rix else None
    hr = one(stats, 1) if stats else None
    hr_avg, hr_max = (one(hr, 2), one(hr, 3)) if hr else (None, None)
    cad = one(stats, 3) if stats else None
    spd = one(stats, 2) if stats else None            # speed km/h {1: avg, 2: max}, as computed by the watch
    res = {
        "startTime": start, "timeZoneOffset": tz, "duration": f"PT{sec:.3f}S",
        "distance": dist, "kiloCalories": kcal, "ascent": ascent,
        "averageHeartRate": hr_avg, "maximumHeartRate": hr_max,
        "sport": SPORTS.get(sport_id, f"SPORT_{sport_id}"),
        "source": "polar_ble (directly from the watch)",
        # the watch stores cadence per leg (strides/min); x2 = steps per minute, as Polar Flow shows it
        "exercises": [{"cadence": {"avg": 2 * one(cad, 1, 0), "max": 2 * one(cad, 2, 0), "unit": "spm"} if cad else None, "samples": {}}],
    }
    if running_index:
        res["exercises"][0]["runningIndex"] = running_index
    if spd and f32(one(spd, 2)):
        res["exercises"][0]["speed"] = {"avg": round(f32(one(spd, 1)) or 0, 2), "max": round(f32(one(spd, 2)), 2)}
    if samples:
        iv = pb_duration(one(samples, 1)) or 1
        s = {"intervalSec": iv,
             "heartRate": packed_varints(fields_of(samples, 2)),
             "cadence": [2 * c for c in packed_varints(fields_of(samples, 4))],   # steps per minute
             "altitude": [round(x, 1) for x in packed(fields_of(samples, 6), "f")],
             "speed": [round(x, 2) for x in packed(fields_of(samples, 9), "f")],
             "distance": [round(x, 1) for x in packed(fields_of(samples, 11), "f")]}
        res["exercises"][0]["samples"] = s
    if route:
        lat, lon = packed(fields_of(route, 2), "d"), packed(fields_of(route, 3), "d")
        t = packed_varints(fields_of(route, 1))
        res["exercises"][0]["route"] = [{"t": t[i] / 1000 if i < len(t) else None, "lat": round(lat[i], 6), "lon": round(lon[i], 6)}
                                        for i in range(min(len(lat), len(lon)))]
    return res


def cmd_training(args):
    import json
    r = decode_training(args.dir)
    sec = float(r["duration"][2:-1])
    km = r["distance"] / 1000
    ex = r["exercises"][0]
    s = ex.get("samples") or {}
    print(f"Start      {r['startTime']}  (UTC{r['timeZoneOffset']/60:+.0f})")
    print(f"Sport      {r['sport']}")
    print(f"Distance   {km:.2f} km   Time {int(sec//3600)}:{int(sec%3600//60):02d}:{int(sec%60):02d}   Pace {int(sec/km//60)}:{int(sec/km%60):02d} /km" if km else "")
    print(f"Heart rate avg {r['averageHeartRate']}  max {r['maximumHeartRate']}   kcal {r['kiloCalories']}   ascent {r['ascent'] and round(r['ascent'])} m")
    if ex.get("cadence"):
        print(f"Cadence    avg {ex['cadence']['avg']}  max {ex['cadence']['max']}")
    for k in ("heartRate", "speed", "distance", "cadence", "altitude"):
        v = s.get(k) or []
        if v:
            print(f"  samples {k:<9} {len(v):>5} values  (interval {s['intervalSec']} s)  e.g. {v[len(v)//2]}")
    if ex.get("route"):
        print(f"  route     {len(ex['route']):>5} GPS points")
    out = os.path.join(args.dir, "training-session.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(r, f)
    print(f"-> {out}")


def cmd_decode(args):
    data = open(args.file, "rb").read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
        print(f"(gunzipped: {len(data)} bytes)")
    dump(data)


def main():
    global DEBUG, BleakScanner, BleakClient
    ap = argparse.ArgumentParser(description="Polar PSFTP over Bluetooth (read-only)")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--pair", action="store_true")
    ap.add_argument("--sync", action="store_true", help="wrap the session in Polar's sync start/stop notifications")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    s = sub.add_parser("services"); s.add_argument("address")
    s = sub.add_parser("ls"); s.add_argument("address"); s.add_argument("path", nargs="?", default="/")
    s = sub.add_parser("get"); s.add_argument("address"); s.add_argument("path"); s.add_argument("outfile", nargs="?")
    s = sub.add_parser("pull"); s.add_argument("address"); s.add_argument("path"); s.add_argument("outdir"); s.add_argument("--depth", type=int, default=6)
    s = sub.add_parser("decode"); s.add_argument("file")
    s = sub.add_parser("zones-put", help="WRITE the heart-rate / pace zones of the running profile (asks first)")
    s.add_argument("address"); s.add_argument("backup", help="PROFILE.BPB downloaded earlier (must match the watch)")
    s.add_argument("--hr", help="6 heart-rate limits, e.g. 50,136,146,156,167,181")
    s.add_argument("--pace", help="4 pace limits from slow to fast (min:sec per km), e.g. 6:03,5:04,4:37,4:16")
    s.add_argument("--slot", default="0", help="sport profile folder (default 0 = running)")
    s.add_argument("--restore", action="store_true", help="write the backup file back unchanged")
    s = sub.add_parser("fav-put", help="WRITE one training favorite to /U/0/FAV/<nn>/ (asks first)")
    s.add_argument("address"); s.add_argument("dir"); s.add_argument("slot")
    s = sub.add_parser("training"); s.add_argument("dir")
    s = sub.add_parser("explore"); s.add_argument("address"); s.add_argument("outdir", nargs="?", default="horloge_dump")
    s = sub.add_parser("all", aliases=["alles"], help="download every training (resumable)")
    s.add_argument("address"); s.add_argument("outdir", nargs="?", default="horloge_data")
    s.add_argument("--since", "--vanaf", dest="since", default="20230101", help="first date, YYYYMMDD")
    s.add_argument("--max", type=int, default=0, help="stop after N new trainings (trial run)")
    s = sub.add_parser("export", aliases=["exporteer"], help="downloaded trainings -> training-session-*.json")
    s.add_argument("indir", nargs="?", default="horloge_data"); s.add_argument("outdir", nargs="?", default="trainingen_json")
    s.add_argument("--full", "--volledig", dest="full", action="store_true", help="also include the GPS route")
    args = ap.parse_args()
    args.cmd = {"alles": "all", "exporteer": "export"}.get(args.cmd, args.cmd)   # old Dutch command names
    DEBUG = args.debug
    if args.cmd == "decode":
        return cmd_decode(args)
    if args.cmd == "export":
        return cmd_export(args)
    if args.cmd == "training":
        return cmd_training(args)
    from bleak import BleakScanner as _S, BleakClient as _C
    BleakScanner, BleakClient = _S, _C
    try:
        asyncio.run(globals()["cmd_" + args.cmd.replace("-", "_")](args))
    except PftpError as e:
        sys.exit(str(e))
    except asyncio.TimeoutError:
        sys.exit("No answer from the watch (timeout).")


if __name__ == "__main__":
    main()
