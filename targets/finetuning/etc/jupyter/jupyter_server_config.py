# jupyter_server_config.py — DROSTE'S BAKED TRAIT DEFAULTS. Installed by
# targets/Container.finetuning to /etc/jupyter/jupyter_server_config.py.
#
# ⭐ THIS IS NOT THE USER'S FILE. The user's file is /opt/data/jupyter_server_config.py,
# seeded once from targets/finetuning/templates/jupyter_server_config.py. This one is
# BAKED INTO THE IMAGE and the user never sees it in their data directory.
#
# ⭐ WHY BAKED AND NOT SEEDED (N1a, the trait half). A seeded file is written
# `if_missing`, so a default that lives there reaches NEW boxes only — every box that
# already exists keeps whatever the old default was, silently. A baked file ships with
# the image, so changing a droste default here actually reaches existing boxes on the
# next pull. That is the whole point of the split.
#
# ⭐ AND THE USER STILL WINS. jupyter_core's jupyter_config_path() returns directories in
# DESCENDING priority and traitlets loads them backwards — `for current in reversed(path)`
# (traitlets/config/application.py:904) — so the SYSTEM directories load FIRST and the
# user's JUPYTER_CONFIG_DIR file loads LAST. Measured at the pins, with this file's values
# in a system dir and the user's in JUPYTER_CONFIG_DIR: a trait set in both resolves to the
# USER's value; a trait set only here reaches ServerApp, LabApp and MappingKernelManager
# alike; and a command-line flag beats both.
#
# 📐 /etc/jupyter, NOT /usr/local/etc/jupyter. On Linux
# SYSTEM_CONFIG_PATH = ["/usr/local/etc/jupyter", "/etc/jupyter"] (jupyter_core/paths.py:
# 358-362) and we deliberately take the LOWER-priority of the two, leaving the other free
# for a local override that must beat droste without touching the image.
# ⚠️ WITH DROSTE_JUPYTER_PLATFORM_DIRS ON, THAT LIST CHANGES. use_platform_dirs()
# (paths.py:342) is read at IMPORT, and with it truthy SYSTEM_CONFIG_PATH becomes
# platformdirs.site_config_dir(...) — measured as ['/etc/xdg/jupyter'], with /etc/jupyter
# not on the path at all. Container.finetuning therefore symlinks /etc/xdg/jupyter to
# /etc/jupyter, so this one file serves both spellings and neither can go stale.
#
# 🚨 BAKING CONVERTS A TRACKING DEFAULT INTO A PINNED ONE. Every value below equals the
# upstream default AT THE PINS (jupyter_server 2.21.0, jupyterlab 4.6.3, jupyterlab_server
# 2.28.0, jupyter_client 8.10.0, traitlets 5.14.3), so this file changes NOTHING today —
# it makes a commented line in the user's file mean exactly one thing, "droste's default",
# instead of sometimes that and sometimes "upstream's, whatever it happens to be".
# The cost is that an upstream default that MOVES at a version bump no longer reaches this
# box, and nothing about the build would say so. That is what the drift report is for:
#
#     podman exec droste-finetuning-halo jupyter-traits-drift.py
#
# Run it whenever the jupyter_server / jupyterlab / traitlets pins move. It compares every
# trait named here against the value the installed packages actually default to, and it
# also catches the second failure mode — a trait upstream has RENAMED, which only warns at
# server start and is easy to never notice.
#
# ⚠️ SIX TRAITS THE USER'S FILE OFFERS ARE DELIBERATELY NOT BAKED. They are listed at the
# bottom of this file with the reason for each. For those, and only those, a commented line
# in the user's file still means "upstream's default".

c = get_config()  # noqa: F821  (injected by traitlets)


# Authentication
# --------------
c.PasswordIdentityProvider.hashed_password = ""
c.PasswordIdentityProvider.password_required = False
c.PasswordIdentityProvider.allow_password_change = True
c.ServerApp.authenticate_prometheus = True
c.ServerApp.disable_check_xsrf = False


# Output Rate Limits
# ------------------
c.ZMQChannelsWebsocketConnection.limit_rate = True
c.ZMQChannelsWebsocketConnection.iopub_data_rate_limit = 1000000.0
c.ZMQChannelsWebsocketConnection.iopub_msg_rate_limit = 1000.0
c.ZMQChannelsWebsocketConnection.rate_limit_window = 3.0


# Idle Kernel Culling
# -------------------
c.MultiKernelManager.default_kernel_name = "python3"
c.MappingKernelManager.cull_idle_timeout = 0
c.MappingKernelManager.cull_interval = 300
c.MappingKernelManager.cull_connected = False
c.MappingKernelManager.cull_busy = False


# Server Lifecycle
# ----------------
c.ServerApp.autoreload = False
c.ServerApp.shutdown_no_activity_timeout = 0
c.ServerApp.quit_button = True
c.Application.log_level = 30


# Files & Storage
# ---------------
c.FileCheckpoints.checkpoint_dir = ".ipynb_checkpoints"
c.FileContentsManager.delete_to_trash = True
c.FileContentsManager.always_delete_dir = False
c.ContentsManager.allow_hidden = False
c.ServerApp.max_body_size = 536870912
c.ServerApp.max_buffer_size = 536870912


# JupyterLab UI State
# -------------------
c.LabApp.default_url = "/lab"
c.LabApp.extra_labextensions_path = []
c.ServerApp.file_to_run = ""


# Outbound Connections
# --------------------
# ⚠️ These three reach the internet at upstream's defaults, and droste keeps them: an
# offline box is a choice the user makes, not one we make for them. The user's own file
# documents the value that turns each call off.
c.LabApp.news_url = "https://jupyterlab.github.io/assets/feed.xml"
# A Type trait accepts the dotted path as a string and imports it; that avoids an import
# at the top of a config file, which would run for every `jupyter` command in the box.
# ⭐ Spelled the way the user's file spells its OFF value ("jupyterlab.NeverCheckForUpdate"):
# jupyterlab/__init__.py re-exports both names, and both resolve — verified at the pin.
c.LabApp.check_for_updates_class = "jupyterlab.CheckForUpdate"
c.LabApp.extension_manager = "pypi"


# Network & Proxying
# ------------------
c.ServerApp.base_url = "/"
c.ServerApp.trust_xheaders = False
c.ServerApp.allow_origin = ""
c.ServerApp.allow_origin_pat = ""
c.ServerApp.local_hostnames = ["localhost"]
c.ServerApp.websocket_ping_interval = 0
c.ServerApp.websocket_ping_timeout = 0
c.ServerApp.websocket_compression_options = None
c.ServerApp.tornado_settings = {}


# ─────────────────────────────────────────────────────────────────────────────
# RESERVED BY DROSTE — set on the command line, not here
# ─────────────────────────────────────────────────────────────────────────────
# ServerApp.ip, ServerApp.port, ServerApp.open_browser and ServerApp.root_dir are set by
# the launcher's argv (build-spec's JUPYTER_ARGV_BASE: --ip, --port, --no-browser,
# --notebook-dir). A command-line flag beats every config file, so a value here would be
# dead text — and dead text that looks authoritative is the defect this file exists to
# remove. The user's template already files them under "Reserved by Droste".
#
#
# ─────────────────────────────────────────────────────────────────────────────
# NOT BAKED, ON PURPOSE — and why
# ─────────────────────────────────────────────────────────────────────────────
# A default that upstream COMPUTES cannot be written down as a literal without freezing
# the computation, and for several of these the computation is exactly what makes an
# advertised environment variable work. Baking them would leave a knob present but inert,
# which is worse than an absent one. Each was read at the pins:
#
#   IdentityProvider.token
#     @default reads JUPYTER_TOKEN, then JUPYTER_TOKEN_FILE, then generates one
#     (jupyter_server/auth/identity.py:209-224). Baking the "" the user's file shows would
#     kill BOTH variables AND turn token auth off — the shown "" is a placeholder for
#     "generated at start", not a default.
#
#   ServerApp.allow_unauthenticated_access
#     @default reads JUPYTER_SERVER_ALLOW_UNAUTHENTICATED_ACCESS (serverapp.py:1348-1350),
#     which is precisely how DROSTE_JUPYTER_ALLOW_UNAUTH_ACCESS reaches the server. A
#     literal here would beat the dynamic default and make that setting do nothing.
#     ⭐ Droste's default for it is delivered by the WIRING instead — build-spec's
#     jupyter_env() pins JUPYTER_SERVER_ALLOW_UNAUTHENTICATED_ACCESS=true.
#
#   LabApp.user_settings_dir / LabApp.workspaces_dir
#     Both are computed AT IMPORT from get_user_settings_dir()/get_workspaces_dir()
#     (jupyterlab/labapp.py:524-528), which read JUPYTERLAB_SETTINGS_DIR /
#     JUPYTERLAB_WORKSPACES_DIR and otherwise derive from jupyter_config_dir()
#     (jupyterlab/commands.py:143-153). Baking the literal they resolve to on THIS box
#     would silence three variables the user's file offers.
#
#   FileContentsManager.preferred_dir
#     @default derives from the parent and carries the deprecation path for the old
#     ServerApp.preferred_dir (filemanager.py:95-96). It resolves to "" here anyway, so baking
#     buys nothing and would remove the migration.
#
#   ServerApp.allow_remote_access
#     @default derives from ServerApp.ip (serverapp.py:1369-1370) — droste sets --ip on the command
#     line, so the derived answer is the correct one. The user's file already files this
#     under "Unused here".
#
#   ServerApp.terminals_enabled
#     @default (serverapp.py:1998-2000) is `return True` today — a computation whose answer
#     happens to be a constant. Excluded anyway, because the rule here is "a default
#     upstream COMPUTES is not baked", and a rule with an exception is worse than no rule:
#     if upstream ever restores the terminado-availability probe that generator used to
#     carry, a baked True would force terminals on where upstream would have turned them
#     off. jupyter-traits-drift.py reports any baked trait that becomes dynamic, which is
#     how this one was caught in the first place.
#
#   ServerApp.jpserver_extensions
#     🚨 MEASURED, and it is not a subtlety: ExtensionApp.initialize_server() constructs
#     the ServerApp with jpserver_extensions={"jupyterlab": True} to force-enable the
#     extension it is launching, and load_config_file() runs AFTERWARDS and REPLACES the
#     trait wholesale. With `= {}` baked, the trait went from {'jupyterlab': True} to {}
#     before the extension manager ever read it. It still loaded, via entry-point
#     discovery — so the damage is silent: the explicit enable that is meant to supersede
#     a disable in config is simply gone.
