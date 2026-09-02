import json, platform, re, sys, time
import urllib.error, urllib.parse, urllib.request

# Both index kinds first, so a multi-arch repo hands back the list rather than
# whichever image the registry guesses we want, then both single-manifest kinds.
ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))
# uname's spelling of a machine is not the registry's spelling of a platform.
ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64",
        "arm64": "arm64", "armv7l": "arm", "ppc64le": "ppc64le",
        "s390x": "s390x", "riscv64": "riscv64"}

deadline = time.time() + 8.0


def budget():
    """Seconds left of the errand, or an exception once there are none."""
    left = deadline - time.time()
    if left <= 0.0:
        raise RuntimeError("timed out")
    return left


def split(repo):
    """registry host + repository name, by the same rule the runtimes use: a
    first component with a dot, a port or the name localhost is a host, and
    anything else is a Docker Hub shorthand. Ours is always ghcr.io; the Hub
    cases are here only so this cannot mislead someone who repoints it."""
    head, _, rest = repo.partition("/")
    if rest and ("." in head or ":" in head or head == "localhost"):
        # docker.io is the name of the Hub, not of the registry that serves it.
        return ("registry-1.docker.io" if head == "docker.io" else head), rest
    return "registry-1.docker.io", repo if "/" in repo else "library/" + repo


def fetch(url, token):
    req = urllib.request.Request(url, headers={
        "Accept": ACCEPT, "User-Agent": "droste-setup"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    return urllib.request.urlopen(req, timeout=budget())


def bearer(host, name, challenge):
    """Anonymous pull token, from the realm the 401 itself named. Public repos
    (ours included) still require this handshake — the answer is just always
    yes — so an unauthenticated GET is expected to be refused exactly once."""
    parts = dict(re.findall(r'([A-Za-z_]+)="([^"]*)"', challenge))
    realm = parts.get("realm") or "https://%s/token" % host
    query = {"scope": parts.get("scope") or "repository:%s:pull" % name}
    if parts.get("service"):
        query["service"] = parts["service"]
    url = realm + "?" + urllib.parse.urlencode(query)
    with urllib.request.urlopen(url, timeout=budget()) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    return body.get("token") or body.get("access_token") or ""


def manifest(host, name, ref, token):
    """One manifest by tag or by digest, acquiring a token if asked to."""
    url = "https://%s/v2/%s/manifests/%s" % (
        host, name, urllib.parse.quote(ref, safe=":@"))
    try:
        with fetch(url, token) as resp:
            return json.loads(resp.read().decode("utf-8")), token
    except urllib.error.HTTPError as exc:
        if exc.code != 401 or token:
            raise
        token = bearer(host, name, exc.headers.get("WWW-Authenticate") or "")
    with fetch(url, token) as resp:
        return json.loads(resp.read().decode("utf-8")), token


try:
    host, name = split(sys.argv[1])
    doc, token = manifest(host, name, sys.argv[2], "")
    if doc.get("manifests"):
        # An index: pick the entry for the machine doing the pulling. Signature
        # and attestation entries live here too, and are filtered out by the
        # same os/architecture test that finds the image.
        want = ARCH.get(platform.machine().lower(), platform.machine().lower())
        pick = ""
        for child in doc["manifests"]:
            plat = child.get("platform") or {}
            if plat.get("os") == "linux" and plat.get("architecture") == want:
                pick = child.get("digest") or ""
                break
        if not pick:
            raise RuntimeError("no linux/%s entry in the index" % want)
        doc, token = manifest(host, name, pick, token)
    blobs = {}
    for blob in (doc.get("layers") or []) + [doc.get("config") or {}]:
        # The config blob is in here on purpose: it is a blob like any other and
        # podman may well report progress for it, and an id the aggregator
        # cannot match is what sends the whole pull back to estimating.
        if blob.get("digest") and isinstance(blob.get("size"), int):
            blobs[blob["digest"]] = blob["size"]
    if not blobs:
        raise RuntimeError("manifest carries no blob sizes")
    sys.stdout.write(json.dumps(blobs))
except Exception as exc:                       # never the reason a pull fails
    sys.stderr.write("pull manifest: %s\n" % exc)
sys.exit(0)
