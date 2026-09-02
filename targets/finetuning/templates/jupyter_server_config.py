# jupyter_server_config.py -- JupyterLab traits (one half of config surface).
#
# This box serves JupyterLab. This file is read because finetuning.cfg sets
# JUPYTER_CONFIG_DIR to this directory. If the variable is changed, move this
# file to the new location.
#
# All settings ship commented out; uncomment a line to set it. Defaults are
# shown in the commented example line and are derived from this image's pinned
# JupyterLab version. Settings reach the server three ways:
#
#   ENVIRONMENT VARIABLES  (/opt/data/finetuning.cfg)
#   This is the only way to assing settings before Jupyter reads any config.
#
#   TRAITS  (/opt/data/jupyter_server_config.py, this file)
#   ServerApp/LabApp settings are in the Python config file. JUPYTER_CONFIG_DIR
#   alerts Jupyter to search the file's path.
#
#     **Misspelled traits / variables yield WARNINGs, not errors; server starts
#     anyway. Check config on boot: server_restart && jupyter lab --show-config
#
#   COMMAND-LINE FLAGS
#   A Jupyter command-line flag overrides all config files.
#
# ** IMPORTANT: If a jupyter_lab_config.py file is created, this file still
# takes precedent over it, even for LabApp traits. However, A JSON file in this
# directory will override this file; it is recommended to stick with this file.
#
# Reserved by Droste (do not set these)
# -------------------------------------
# Droste needs these arguments to be unchanged for setup & teardown; changes
# are likely to break the box boot, services, and/or functionality.
#
# c.ServerApp.ip / .port / .open_browser -- set on the command line by Droste;
#   the port comes from PORT in /opt/data/server.env.
# c.ServerApp.root_dir = "/opt/workspace"    # OVERRIDDEN by --notebook-dir

c = get_config()  # noqa: F821  (injected by traitlets)


# Authentication
# --------------
# c.IdentityProvider.token = ""                   # default: generated at start
# c.PasswordIdentityProvider.hashed_password = ""
# c.PasswordIdentityProvider.password_required = False
# c.PasswordIdentityProvider.allow_password_change = True
# c.ServerApp.allow_unauthenticated_access = True
# c.ServerApp.authenticate_prometheus = True
# c.ServerApp.disable_check_xsrf = False


# Output Rate Limits
# ------------------
# c.ZMQChannelsWebsocketConnection.limit_rate = True            # master switch
#
# c.ZMQChannelsWebsocketConnection.iopub_data_rate_limit = 1000000.0  # bytes/s
# c.ZMQChannelsWebsocketConnection.iopub_msg_rate_limit = 1000.0      # msgs/s
# c.ZMQChannelsWebsocketConnection.rate_limit_window = 3.0            # seconds


# Idle Kernel Culling
# -------------------
# c.MultiKernelManager.default_kernel_name = "python3"
#
# c.MappingKernelManager.cull_idle_timeout = 0     # seconds; 0 = never cull
# c.MappingKernelManager.cull_interval = 300       # how often to check
# c.MappingKernelManager.cull_connected = False    # cull with browser attached
# c.MappingKernelManager.cull_busy = False         # cull even while executing


# Server Lifecycle
# ----------------
# c.ServerApp.autoreload = False
# c.ServerApp.shutdown_no_activity_timeout = 0     # seconds; 0 = never
# c.ServerApp.quit_button = True                   # the UI's shutdown button
# c.Application.log_level = 30                     # 10 = DEBUG


# Files & Storage
# ---------------
# c.FileCheckpoints.checkpoint_dir = ".ipynb_checkpoints"
# c.FileContentsManager.delete_to_trash = True
# c.FileContentsManager.always_delete_dir = False  # else non-empty dirs refuse
# c.FileContentsManager.preferred_dir = ""         # landing dir inside root
# c.ContentsManager.allow_hidden = False           # show dotfiles in browser
#
# c.ServerApp.max_body_size = 536870912      # 512 MiB upload ceiling
# c.ServerApp.max_buffer_size = 536870912


# JupyterLab UI State
# -------------------
# c.LabApp.user_settings_dir = "/opt/data/lab/user-settings"
# c.LabApp.workspaces_dir = "/opt/data/lab/workspaces"
# c.LabApp.default_url = "/lab"
# c.LabApp.extra_labextensions_path = []
# c.ServerApp.file_to_run = ""                     # open a notebook on start


# Outbound Connections
# --------------------
# These three ship at upstream's defaults, which all reach the internet. The
# value on the right of each arrow turns that call off.
#
# c.LabApp.news_url = "https://jupyterlab.github.io/assets/feed.xml"
#   -> None                                 # stop fetching announcements
# c.LabApp.check_for_updates_class = "jupyterlab.CheckForUpdate"
#   -> "jupyterlab.NeverCheckForUpdate"     # stop version checks
# c.LabApp.extension_manager = "pypi"
#   -> "readonly"                           # browse extensions, never install


# Network & Proxying
# ------------------
# c.ServerApp.base_url = "/"
# c.ServerApp.trust_xheaders = False
# c.ServerApp.allow_origin = ""                    # CORS
# c.ServerApp.allow_origin_pat = ""
# c.ServerApp.local_hostnames = ["localhost"]
# c.ServerApp.websocket_ping_interval = 0          # long training cells vs an
# c.ServerApp.websocket_ping_timeout = 0           # idle-timeout proxy
# c.ServerApp.websocket_compression_options = None
# c.ServerApp.tornado_settings = {}


# Terminals
# ---------
# c.ServerApp.terminals_enabled = True
# c.ServerApp.jpserver_extensions = {}  # module name -> load it? (alphabetical)
#   to switch terminals off use terminals_enabled above; this is the general
#   knob, e.g. {"jupyter_server_terminals": False}



# Unused here (inapplicable / overridden by Droste) <-- Need to fix TLS.
# -------------------------------------------------
# c.ServerApp.keyfile / .certfile / .client_ca -- HTTPS. Breaks healthcheck.
#
# c.ServerApp.allow_remote_access = True  # Overridden by ip configuration.
