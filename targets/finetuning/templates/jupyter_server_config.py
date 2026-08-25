# jupyter_server_config.py -- JupyterLab traits (the other half of this box's
# config surface; the first half is /opt/data/finetuning.env).
#
# Seeded to /opt/data/jupyter/ on first start and NEVER overwritten -- your edits
# here win. Everything ships commented out; uncomment a line to set it. Defaults
# are the ones measured on this image's pinned JupyterLab.
#
# This file is only read because finetuning.env sets JUPYTER_CONFIG_DIR to the
# directory it lives in. If you comment that variable out, move this file to
# ~/.jupyter or it stops taking effect.
#
# ** A misspelled trait is a WARNING, not an error, and the server starts anyway.
# After editing:  server_restart && jupyter lab --show-config
#
# ** A command-line flag beats this file, always. The flags droste sets (--ip,
# --port, --notebook-dir, --no-browser, --allow-root) therefore win over the
# matching traits below, which is why those traits are marked "overridden".
#
# ** jupyter_lab_config.py, if you create one, LOSES to this file even for LabApp
# traits -- and a .json in this directory beats this .py. Keep it all here.

c = get_config()  # noqa: F821  (injected by traitlets)


# Authentication
# --------------
# A password is the alternative to the token in finetuning.env, and setting one
# suppresses the token entirely.
#
# ** Generate the hash with `jupyter lab password`, which writes
# IdentityProvider.hashed_password into jupyter_server_config.json at mode 0600.
# Do NOT follow recipes using `python -m jupyter_server.auth password`: that
# writes the DEPRECATED ServerApp.password key, world-readable at 0644.
#
# c.IdentityProvider.token = ""                    # default: regenerated per start
# c.PasswordIdentityProvider.hashed_password = ""  # default: ""
# c.PasswordIdentityProvider.password_required = False
# c.PasswordIdentityProvider.allow_password_change = True
# c.ServerApp.allow_unauthenticated_access = True  # unruled endpoints answer w/o auth
# c.ServerApp.disable_check_xsrf = False           # the usual fix for scripted API use
# c.ServerApp.authenticate_prometheus = True       # /metrics needs auth


# Output Rate Limits
# ------------------
# ** THE CLASSIC FINE-TUNING FOOTGUN. A training loop printing per-step loss
# exceeds 1 MB/s and JupyterLab starts DROPPING output ("IOPub data rate
# exceeded") -- your run keeps going, your log does not.
#
# ** Set them on ZMQChannelsWebsocketConnection, NOT on ServerApp. The
# ServerApp.iopub_data_rate_limit that older answers recommend is a deprecated
# shim; setting it has no effect and reports no error.
#
# c.ZMQChannelsWebsocketConnection.iopub_data_rate_limit = 1000000.0   # bytes/s
# c.ZMQChannelsWebsocketConnection.iopub_msg_rate_limit = 1000.0       # msgs/s
# c.ZMQChannelsWebsocketConnection.rate_limit_window = 3.0             # seconds
# c.ZMQChannelsWebsocketConnection.limit_rate = True                   # master switch


# Idle Kernel Culling
# -------------------
# ** THIS IS THE MEMORY KNOB ON THIS HARDWARE. System RAM and VRAM are the same
# pool on Strix Halo, so a forgotten kernel holding a loaded model is memory the
# next run does not get. Culling is OFF by default.
#
# c.MappingKernelManager.cull_idle_timeout = 0     # seconds; 0 = never cull
# c.MappingKernelManager.cull_interval = 300       # how often to check
# c.MappingKernelManager.cull_connected = False    # cull even with a browser attached
# c.MappingKernelManager.cull_busy = False         # cull even while executing
# c.MultiKernelManager.default_kernel_name = "python3"


# Server Lifecycle
# ----------------
# ** BOTH OF THESE FIGHT THE SUPERVISOR. The box's healthcheck restarts the
# container when the server stops answering, so a server that shuts itself down
# is one the box will bring straight back up -- possibly in a loop. Use
# `server_stop` to stop serving on purpose; it records the intent.
#
# c.ServerApp.shutdown_no_activity_timeout = 0     # seconds; 0 = never
# c.ServerApp.quit_button = True                   # the UI's shutdown button
# c.ServerApp.autoreload = False
# c.Application.log_level = 30                     # 10 = DEBUG, on a box whose
#                                                  # only diagnostic is a log file


# Files & Storage
# ---------------
# ** delete_to_trash MOVES, it does not free space, and /opt/workspace is a
# different device from your home -- so a deleted notebook lands in
# /opt/workspace/.Trash-<uid>/ and stays there forever. Set it False to delete
# for real. (If that directory is not writable, deletes fail outright with
# "send2trash failed".)
#
# c.FileContentsManager.delete_to_trash = True
# c.FileContentsManager.always_delete_dir = False  # else non-empty dirs refuse
# c.FileContentsManager.preferred_dir = ""         # landing dir inside the root
# c.ContentsManager.allow_hidden = False           # show dotfiles in the browser
# c.FileCheckpoints.checkpoint_dir = ".ipynb_checkpoints"  # written beside every
#                                                  # notebook, i.e. across your bind
# c.ServerApp.max_body_size = 536870912            # 512 MiB upload ceiling
# c.ServerApp.max_buffer_size = 536870912
# c.ServerApp.root_dir = "/opt/workspace"          # OVERRIDDEN by --notebook-dir.
#                                                  # ** The directory must exist:
#                                                  # a missing root is a hard start
#                                                  # failure, not a warning.


# JupyterLab UI State
# -------------------
# Themes, keymaps, editor preferences and saved tab layouts. Left at their
# defaults these land under the home directory, which in the server lane is
# /root and is lost when the container is recreated. Point them at /opt/data to
# keep them per-box and persistent.
#
# c.LabApp.user_settings_dir = "/opt/data/jupyter/lab/user-settings"
# c.LabApp.workspaces_dir = "/opt/data/jupyter/lab/workspaces"
# c.LabApp.default_url = "/lab"
# c.LabApp.extra_labextensions_path = []
# c.ServerApp.file_to_run = ""                     # open a notebook on start


# Outbound Connections
# --------------------
# ** THIS IMAGE PHONES HOME THREE WAYS BY DEFAULT: a news feed, a version check
# against PyPI, and the extension manager querying PyPI when its UI is opened.
# These three lines close all three.
#
# c.LabApp.news_url = None
# c.LabApp.check_for_updates_class = "jupyterlab.NeverCheckForUpdate"
# c.LabApp.extension_manager = "readonly"


# Network & Proxying
# ------------------
# base_url is what makes a reverse proxy at a sub-path (/finetuning/) possible;
# trust_xheaders is what makes an SSL-terminating proxy in front of it work.
#
# c.ServerApp.base_url = "/"
# c.ServerApp.trust_xheaders = False
# c.ServerApp.allow_origin = ""                    # CORS
# c.ServerApp.allow_origin_pat = ""
# c.ServerApp.local_hostnames = ["localhost"]
# c.ServerApp.websocket_ping_interval = 0          # long training cells vs an
# c.ServerApp.websocket_ping_timeout = 0           # idle-timeout proxy
# c.ServerApp.websocket_compression_options = None
# c.ServerApp.tornado_settings = {}
# c.ServerApp.allow_remote_access = True           # OVERRIDDEN: --ip 0.0.0.0 turns
#                                                  # this on and it cannot be turned
#                                                  # back off from here. To stop
#                                                  # serving the LAN, put
#                                                  # --ip 127.0.0.1 in
#                                                  # JUPYTER_DROSTE_EXTRA_ARGS.


# Terminals
# ---------
# ** Terminals are ON, and this trait alone does not switch them off -- the
# server extension has to go too, which is the second line.
#
# c.ServerApp.terminals_enabled = True
# c.ServerApp.jpserver_extensions = {"jupyter_server_terminals": False}


# Unused here (inapplicable / overridden by droste)
# -------------------------------------------------
# c.ServerApp.keyfile / .certfile / .client_ca -- HTTPS. The healthcheck probes
#   this box over plain http on 127.0.0.1 with the scheme hardcoded, so enabling
#   TLS here makes every probe fail and the supervisor restart the container in a
#   loop. Terminate TLS in a proxy in front of the box instead.
# c.ServerApp.ip / .port / .open_browser -- set on the command line by droste;
#   the port comes from PORT in /opt/data/server.env.
