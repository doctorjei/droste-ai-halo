import json, sys, threading, time

label, width, fill, empty, plain = sys.argv[1:6]
width = int(width)
ascii_mode = plain == "1"
out = sys.stdout

raw = sys.argv[6] if len(sys.argv) > 6 else ""
# The --ascii block is a drawing of its own (Jei's s39 spec) and REPLACES the
# status line the caller would otherwise have opened, so it needs three things
# the repainting bar does not: the image ref in FULL (it gets a line to itself,
# so there is no reason to shorten it), the name-column width that fixes where
# the [OK] tag ends, and a file to report the column it stopped on — which is
# what lets status_ok/status_err pad from there to the tag.
alabel = sys.argv[7] if len(sys.argv) > 7 else label
statw = int(sys.argv[8]) if len(sys.argv) > 8 else 53
colfile = sys.argv[9] if len(sys.argv) > 9 else ""
known = {}                                     # blob digest (bare hex) -> size
try:
    for digest, size in (json.loads(raw) if raw.strip() else {}).items():
        known[digest.split(":")[-1].lower()] = int(size)
except (AttributeError, TypeError, ValueError):
    known = {}                                 # unreadable map is simply no map
fixed_total = sum(known.values())

layers = {}                                    # id -> [current, total]
state = {"seen": False, "last": 0.0, "extract": set(),
         "fixed": bool(known), "map": {}}
dec = json.JSONDecoder()


def degrade():
    """Stop trusting the manifest, for the rest of this pull.

    A single id the map cannot account for means the map does not describe this
    stream, and half-mapped arithmetic is worse than none. Every layer already
    carries its own current/total, so the running sum simply resumes from what
    has been collected — nothing is lost and nothing is counted twice."""
    state["fixed"] = False


def mapped(lid):
    """The size of the blob a stream id names, or None if that is not certain.

    The stream shortens digests to a prefix, so the match is by prefix; a
    prefix that hits two blobs, or none, counts as no match rather than as
    licence to charge bytes to the wrong layer."""
    if lid not in state["map"]:
        key = lid.lower().split(":")[-1]
        hit = [h for h in known if h.startswith(key)]
        state["map"][lid] = known[hit[0]] if len(hit) == 1 else None
    return state["map"][lid]


def sizes(cur, tot, guess):
    mark = "~" if guess else ""
    for unit, div in (("GB", 1 << 30), ("MB", 1 << 20)):
        if tot >= div:
            return "%.1f/%s%.1f %s" % (
                cur / float(div), mark, tot / float(div), unit)
    return "%.0f/%s%.0f KB" % (cur / 1024.0, mark, tot / 1024.0)


# ── The --ascii drawing: APPEND-ONLY ────────────────────────────────────────
# No CR, no erase-line, nothing outside {0x20-7E, LF}: this is the form that
# survives a pipe, a log file and a dumb terminal, which is why it exists at
# all (the repainting bar below simply had nothing to repaint with there, and
# was switched off). Terminal mode is untouched.
#
# CAP is the right edge of the [OK] tag — the same column every other status
# line in this section ends on (2 indent + name column + 4), which is 59 for a
# full run. A bar row's own content stops five short of that, leaving " [OK]"
# for the caller to print. The block itself is drawn flush left: it is a
# full-width drawing, like a rule, whose closing tag lands in the tag column.
CAP = 2 + statw + 4
ANN = CAP - 5                                  # right edge of a row's content
ROW_MARKS = 50                                 # 100 marks (one per percent), 2 rows

# col = the column the open line has reached; row = marks/dots on it.
A = {"col": 0, "row": 0, "marks": 0, "dots": 0, "closed": False,
     "t0": time.time(), "done": False}
lock = threading.Lock()                        # the minute clock writes too


def fmt_size(n):
    """3 significant characters, then the unit: "6.6 GiB" / " 66 MiB" / "999 B"."""
    for unit, div in (("TiB", 1 << 40), ("GiB", 1 << 30),
                      ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if n >= div:
            v = n / float(div)
            return "%s %s" % ("%.1f" % v if v < 10 else "%3d" % int(v), unit)
    return "%3d B" % int(n)


def fmt_time(m, level=0):
    """Elapsed minutes. level is the compression rung: the full form, the same
    thing without a day field (36h 07m), then bare minutes (2167m)."""
    if level >= 2:
        return "%dm" % m
    day, rem = divmod(m, 1440)
    if level == 0 and day:
        return "%dd %dh %02dm" % (day, rem // 60, rem % 60)
    if m >= 60:
        return "%dh %02dm" % (m // 60, m % 60)
    return "%dm" % m


def reserve_w(m):
    """Room to keep for the NEXT order of magnitude, so the annotation does not
    have to move once it grows: 36m -> 1h 11m -> 10h 46m -> 1d 12h 07m."""
    w = len(fmt_time(m))
    return {2: 3, 3: 6, 6: 7, 7: 10}.get(w, w + 1)


def dot_cap(m):
    """Dots a row may hold: its one-character prefix, then whatever is left
    before the widest annotation this row could still have to print."""
    return ANN - 1 - (4 + reserve_w(m) + 7)


def cur_bytes():
    return sum(v[0] for v in layers.values())


def write(s):
    out.write(s)
    A["col"] += len(s)


def newrow():
    out.write("\n ")                           # every row after the first
    A["col"] = 1
    A["row"] = 0


def annot(final):
    """(elapsed, bytes) while running; SQUARE brackets on the final row. It is
    right-aligned to ANN, and degrades in Jei's order when it will not fit:
    first the gap before it is eaten, then the time field is compressed. If
    even that is too wide it prints anyway and wraps — we got super unlucky."""
    room = ANN - A["col"]
    lb, rb = ("[", "]") if final else ("(", ")")
    for level in (0, 1, 2):
        text = "%s%s, %s%s" % (lb, fmt_time(A["dots"], level),
                               fmt_size(cur_bytes()), rb)
        if len(text) <= room:
            break
    pad = room - len(text)
    write(" " * (pad if pad > 0 else 0) + text)


def ascii_open():
    """The header, printed before the first byte: the ref, then the size the
    manifest prefetch found — or the fact that it did not — right-aligned to
    CAP. Then the bar opens, so a registry that never answers still shows that
    something was asked."""
    tag = "(%s)" % fmt_size(fixed_total) if fixed_total else "(Size: ???)"
    # The cap governs, so the gap is what gives: the longest ref this installer
    # pulls (finetuning) leaves exactly none of it, and "latest...(4.6 GiB)" at
    # 59 is the same trade the annotation rows make one rung down the ladder.
    pad = CAP - len(alabel) - len(tag)
    out.write("%s%s%s\n[" % (alabel, " " * (pad if pad > 0 else 0), tag))
    A["col"] = 1
    out.flush()


def ascii_marks(pct):
    """Size known: one mark per percent, 50 to a row. The manifest's total is
    the denominator for the whole pull — a mid-flight degrade() cannot be
    honoured by ink already on the page, and the prefetched size is the true
    one anyway; only the mapping of stream ids to blobs was ever in doubt."""
    while A["marks"] < pct:
        if A["row"] >= ROW_MARKS:
            newrow()
        write(fill)
        A["marks"] += 1
        A["row"] += 1
    if A["marks"] >= 100 and not A["closed"]:
        write("]")
        A["closed"] = True


def ascii_dots(upto):
    """Size unknown: one dot per elapsed minute. A row closes with its own
    cumulative annotation the moment another dot would not leave room for it."""
    while A["dots"] < upto:
        if A["row"] >= dot_cap(A["dots"]):
            annot(False)
            newrow()
        write(".")
        A["dots"] += 1
        A["row"] += 1


def paint_ascii(final=False):
    with lock:
        if A["done"]:
            return
        if fixed_total:
            ascii_marks(100 if final
                        else min(100, int(cur_bytes() * 100 // fixed_total)))
        else:
            ascii_dots(int((time.time() - A["t0"]) // 60))
            if final:
                annot(True)
        A["done"] = final
        out.flush()


def ascii_clock():
    """Estimating mode polls on its own: a pull that has gone quiet is exactly
    the moment the reader most needs to see the minutes still ticking."""
    while True:
        time.sleep(2)
        with lock:
            if A["done"]:
                return
            ascii_dots(int((time.time() - A["t0"]) // 60))
            out.flush()


def ascii_report():
    """Where the block stopped, for the caller's [OK]/[ERROR] tag."""
    with lock:
        A["done"] = True
        out.flush()
        if colfile:
            try:
                with open(colfile, "w") as fh:
                    fh.write("%d\n" % A["col"])
            except OSError:                     # never the reason a pull fails
                pass


def paint(final=False):
    if ascii_mode:
        paint_ascii(final)
        return
    now = time.time()
    if not final and now - state["last"] < 0.1:
        return
    state["last"] = now
    cur = sum(v[0] for v in layers.values())
    # Fixed: the whole image, known before the first byte. Otherwise: only the
    # layers that have announced themselves, which is why that total climbs.
    tot = fixed_total if state["fixed"] else sum(v[1] for v in layers.values())
    if final:
        pct = 100
    elif tot:
        pct = min(100, int(cur * 100 // tot))
    else:
        pct = 0
    if state["extract"] and (not tot or cur >= tot):
        tail = "  %3d%%  extracting" % pct
    elif tot:
        tail = "  %3d%%  %s" % (pct, sizes(cur, tot, not state["fixed"]))
    else:
        tail = "  %3d%%" % pct           # every layer cached: no bytes to count
    # The tail is padded to a fixed width so the bar cannot change length
    # mid-download (the size text grows by a digit as it climbs). The pad is
    # the widest either mode can print — "  100%  1234.5/~1234.5 GB" — and it
    # is deliberately ONE number for both, because a pull that falls back to
    # estimating mid-flight must not resize the bar as it does so.
    tail = tail.ljust(25)
    room = width - 4 - len(label) - len(tail)
    if room >= 8:
        n = min(room, 40)
        done = n * pct // 100
        line = "  %s  %s%s" % (label, fill * done + empty * (n - done), tail)
    else:
        line = "  %s%s" % (label, tail)
    out.write("\r" + line + "\x1b[K")
    out.flush()


def handle(o):
    state["seen"] = True
    if o.get("error") or o.get("errorDetail"):
        msg = o.get("error") or (o.get("errorDetail") or {}).get("message")
        sys.stderr.write("pull API: %s\n" % (msg or "unknown error"))
        sys.exit(1)
    st = o.get("status") or ""
    lid = o.get("id") or ""
    if not lid:
        return
    pd = o.get("progressDetail") or {}
    if st.startswith("Already exists"):
        # A cached layer is finished, not absent. With a manifest we know how
        # many bytes it stands for, so the bar jumps FORWARD over it instead of
        # the total quietly shrinking around a layer worth nothing.
        size = mapped(lid) if state["fixed"] else None
        if state["fixed"] and size is None:
            degrade()
        if size is None:
            layers.setdefault(lid, [0, 0])
        else:
            layers[lid] = [size, size]
    elif st.startswith("Downloading"):
        got, size = int(pd.get("current") or 0), int(pd.get("total") or 0)
        if state["fixed"]:
            mapped_size = mapped(lid)
            if mapped_size is None:
                degrade()
            else:
                size = mapped_size
        layers[lid] = [got, size]
    elif st.startswith("Download complete") or st.startswith("Pull complete"):
        if lid in layers:
            layers[lid][0] = layers[lid][1]
        state["extract"].discard(lid)
    elif st.startswith("Extracting"):
        state["extract"].add(lid)
    paint()


if ascii_mode:
    ascii_open()
    if not fixed_total:
        threading.Thread(target=ascii_clock, daemon=True).start()

try:
    buf = ""
    for chunk in sys.stdin:
        buf += chunk
        while True:
            buf = buf.lstrip()
            if not buf:
                break
            try:
                obj, idx = dec.raw_decode(buf)
            except ValueError:
                break
            buf = buf[idx:]
            handle(obj)

    if not state["seen"]:
        sys.stderr.write("pull API: no progress stream received\n")
        sys.exit(1)
    paint(final=True)
finally:
    # Reached on the error paths too: a half-drawn row still has to tell the
    # caller which column its [ERROR] tag pads from.
    if ascii_mode:
        ascii_report()
