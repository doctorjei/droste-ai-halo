# droste_dlwatch_shim.py — the N24 P4 in-process shim (R4).
#
# Imported at interpreter startup by `zz_droste_dlwatch.pth` (one line:
# `import droste_dlwatch_shim`). It wraps huggingface_hub's single download funnel,
# `_download_to_tmp_and_move`, so the *expected total* — which hub holds only in
# memory — is written to disk where the droste download watcher can read it.
#
# WHAT IT WRITES. A sidecar named for the partial it annotates:
#     blobs/<etag>.incomplete            -> blobs/<etag>.total        (hub 0.x)
#     blobs/<etag>.<uuid8>.incomplete    -> blobs/<etag>.total        (hub 1.x)
# holding one ASCII integer, the expected total in bytes. The watcher reads it and
# emits a real percentage; with no sidecar it emits its usual bytes-and-rate line
# unchanged, so a box without the shim degrades silently to P1 behaviour.
#
# 🚨 THE GUARD IS THE POINT. hub's own circular import means patching *eagerly* at
# import time raises, and hub SWALLOWS the error — the patch then never installs while
# downloads succeed, silently (design §2b). So we do not patch on import; we register
# a lazy patcher on the module and only wrap the funnel once it exists. If hub has no
# such funnel (a future version that renamed it), we warn once and do nothing — never
# a wrong percentage, never a box-killer.
#
# Everything here is defensive: a shim that can take down the server it annotates is
# worse than no shim. Any internal failure is caught, warned about once, and ignored.

import os
import sys

_WARNED = set()


def _warn(msg):
    # One line per distinct message, to stderr, and never twice. The server's log is
    # the surface; a shim that spams on every download is its own defect.
    if msg in _WARNED:
        return
    _WARNED.add(msg)
    try:
        sys.stderr.write("droste-download shim: %s\n" % msg)
    except Exception:
        pass


def _sidecar_for(incomplete_path):
    """Return the sidecar path for a partial, or None if it is not a hub cache partial.

    The watcher's `.incomplete` name is the finished blob's name: hub builds
    blob_path = blobs/<etag> and the partial is `<blob_path>.incomplete`, with hub 1.x
    inserting a per-attempt `.<uuid8>` before the suffix. Strip the suffix (and the
    uuid8 when present) to recover the blob stem, then append `.total`.
    """
    try:
        name = str(incomplete_path)
    except Exception:
        return None
    if not name.endswith(".incomplete"):
        return None
    stem = name[: -len(".incomplete")]
    # hub 1.x per-attempt suffix: strip a trailing .<8 hex> (an etag contains no dot,
    # so this can only ever be the uuid).
    base = os.path.basename(stem)
    if "." in base:
        head, _, tail = base.rpartition(".")
        if head and len(tail) == 8 and all(c in "0123456789abcdefABCDEF" for c in tail):
            stem = os.path.join(os.path.dirname(stem), head)
    return stem + ".total"


def _write_total(incomplete_path, expected_size):
    """Write the expected-total sidecar. Idempotent and atomic; failures are non-fatal."""
    if expected_size is None:
        return
    try:
        size = int(expected_size)
    except (TypeError, ValueError):
        return
    sidecar = _sidecar_for(incomplete_path)
    if sidecar is None:
        return
    try:
        # Don't rewrite an identical sidecar on every resume; the value cannot change
        # for a given blob, and skipping the write keeps resume cheap.
        if os.path.exists(sidecar):
            try:
                with open(sidecar, "r", encoding="ascii") as fh:
                    if fh.read().strip() == str(size):
                        return
            except OSError:
                pass
        tmp = sidecar + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="ascii") as fh:
            fh.write(str(size))
        os.replace(tmp, sidecar)
    except OSError as exc:
        _warn("could not write %s (%s); no percentage for this download" % (sidecar, exc))


def _patch(hub_module):
    """Wrap the funnel once it exists. Returns True once patched."""
    funnel = getattr(hub_module, "_download_to_tmp_and_move", None)
    if funnel is None:
        return False
    if getattr(funnel, "_droste_dlwatch_wrapped", False):
        return True

    def wrapper(incomplete_path, destination_path, url_to_download, *args, **kwargs):
        # expected_size is an int-or-None in BOTH majors. proxies/headers/xet_file_data
        # are never a plain int, so the first non-bool int among the args IS
        # expected_size regardless of how many container args precede it (2 in 0.x,
        # 1 in 1.x). A bool is excluded because Python bools are ints.
        expected = kwargs.get("expected_size")
        if expected is None:
            for a in args:
                if isinstance(a, int) and not isinstance(a, bool):
                    expected = a
                    break
        _write_total(incomplete_path, expected)
        return funnel(incomplete_path, destination_path, url_to_download, *args, **kwargs)

    wrapper._droste_dlwatch_wrapped = True
    try:
        hub_module._download_to_tmp_and_move = wrapper
    except Exception as exc:  # pragma: no cover - extremely defensive
        _warn("could not install the download shim (%s)" % exc)
        return False
    return True


def _install():
    try:
        import huggingface_hub.file_download as fd
    except Exception:
        # huggingface_hub is not importable in this process (e.g. llama has none, and
        # tools that never download). That is fine — the shim is inert there.
        return
    if _patch(fd):
        return
    # The funnel was not there yet (circular import) or does not exist. Retry lazily on
    # first attribute access via a module __getattr__ hook is overkill; instead retry on
    # the next import attempt by hooking the module's __class__ is fragile. The robust
    # move: warn once if the funnel is genuinely absent after hub is fully imported.
    if not hasattr(fd, "_download_to_tmp_and_move"):
        _warn(
            "huggingface_hub %s has no _download_to_tmp_and_move; no percentage for "
            "downloads on this box" % getattr(
                __import__("huggingface_hub"), "__version__", "?")
        )


_install()
