# ── Dry run ──────────────────────────────────────────────────────────────────
# 🏁 THE GOVERNING RULE, AND IT IS THE WHOLE SPECIFICATION (Jei, s79):
#
#     "a dry run never changes the disk"
#
# ⭐⭐ EVERY CASE-BY-CASE ANSWER FOLLOWS FROM IT, which is the test that it is the
# right rule: do not pull (writes ~14 GB) · do query the registry (reads only) ·
# do not create a directory the user named · do not FAKE one on disk either ·
# model it in memory instead · do not write an ini, a .cfg or a unit · do run
# `podman ps` / `inspect` (reads) · do not stop or start a box. Apply it to
# anything this file does not anticipate.
#
# 🏁 AND THE SECOND HALF OF THAT RULING SAYS WHAT THE OUTPUT IS FOR (Jei, s79):
# "we should see if the empty directories exist, that the permissions are
# available, etc — i.e., 'could we do this'."
# ⭐⭐ A DRY RUN IS A REHEARSAL, NOT A NARRATION. It answers *could we do this*,
# not merely *what would we do* — which is the difference between a tool that
# states its intentions and one that PREVENTS the failure, at the moment the
# failure is still free to avoid.
# ⚠️ A FEASIBILITY CHECK IS ITSELF A PREDICTION AND MUST NOT OVERCLAIM. "The
# parent is writable" is a strong proxy for "the mkdir will work", NOT a proof —
# quota, immutable flags and LSM denials all sit outside it. The vocabulary is
# "appears possible", never "will succeed".
#
# ── WHY THIS IS A CHOKE POINT AND NOT N SCATTERED `if [[ $DRY_RUN ]]` GUARDS ──
# 🚨 ONE MISSED SITE IS A DRY RUN THAT SILENTLY IS NOT ONE — this project's own
# named defect (a knob that looks authoritative and does nothing) pointed at the
# most destructive surface we have, and aimed at a user who has just been told
# nothing will happen. Scattered guards cannot be checked; two wrappers can.
# ⭐ `scripts/check-installer-dryrun.sh` IS THE DELIVERABLE, not these functions.
# It walks the call graph from `main` and asserts no mutation is reachable
# without passing one of these, DERIVING the mutating set from the tree rather
# than carrying a list — because a list is exactly what rots when someone adds a
# writer, and it rots SILENTLY.
#
# ── WHY THIS FRAGMENT SITS ABOVE `ui.sh` IN THE MANIFEST ─────────────────────
# ⚠️ NOT ARBITRARY, AND DO NOT MOVE IT DOWN. `ask_path_as` and `ask_path_or_none`
# create a directory the user named, so they are mutation sites INSIDE the UI
# layer — and that layer's rule 2 forbids it from calling anything defined
# BELOW it. Defined ABOVE, these are reachable by exactly the same allowance
# `usage()` already relies on ("reaching up to the help text a host program
# supplies is how the layer gets one").
# ⚠️ AND THE STATE VARIABLE IS `ARG_DRY_RUN`, ASSIGNED ONLY BY THE OPTION LOOP,
# for the same layering reason: `check-installer-layering.sh` DERIVES its
# forbidden set as "every SHOUTING-CASE name the program assigns outside the
# layer", so a `DRY_RUN` assigned here would become a name the option loop is
# forbidden to touch. Assigned in the loop and only READ here, it is a layer
# output — the same shape, and the same wart, as `ARG_BOXES`.
# ⚠️ The palette (`C_TEXT`, `C_NOTB`, `RESET`) is read at CALL time, long after
# `ui.sh` has run — and so is `path_within`, the ONE ui.sh function this file
# calls. ⭐ THAT IS THE WHOLE LICENCE AND IT IS EXACTLY AS NARROW AS THE PALETTE
# ONE: a name written here is resolved when the call HAPPENS, not when the file
# is read, and nothing in this file runs during sourcing. What is forbidden is
# reaching a ui.sh definition at SOURCE time, which no line here does.
# 🚨 AND THE EXCEPTION IS NOT AN ARBITRARY PICK — IT IS THE PATH SPELLING
# CONTRACT. That contract says to compare directories with `same_dir` /
# `path_within` and NEVER with `==`, because two spellings of one directory must
# not read as two places. A second comparator written HERE to dodge the forward
# reference would be a FORK of the contract's own comparator, which is a worse
# outcome than the reference by every measure this project uses.

# Is this a dry run? Every guard in the program asks it this way rather than
# testing the variable, so the one place that decides can grow a second
# condition (a --dry-run-logged, say) without a sweep.
dry::on() { [[ ${ARG_DRY_RUN:-0} -eq 1 ]]; }

# ── The line kinds (§4 of the plan) ──────────────────────────────────────────
# 🚨 A DRY RUN CANNOT BE PERFECTLY FAITHFUL, AND THE REASON IS STRUCTURAL: later
# answers depend on earlier effects. Decline to create a directory and the next
# check — is it empty? has it room? is there data here? — gets a DIFFERENT
# answer, so everything downstream of that point may diverge from what a real
# run would do.
# ⭐ THE ANSWER IS NOT TO FAKE THE DIRECTORY AND NOT TO CREATE IT. It is to SAY
# SO where it happens. A dry run that quietly presents a divergent prediction as
# fact is worse than no dry run, because it will be trusted exactly once.
#
#   WOULD DO              an action, predicted against real state
#   DRY RUN: simulating…  an ASSUMPTION being injected into the model — the
#                         consequence of an action that was not taken
#
# ⭐⭐ THE SIMULATION LINE IS WHAT MAKES MODELING SAFE RATHER THAN MERELY
# CONVENIENT: an ANNOUNCED assumption is auditable — the reader sees precisely
# what was pretended and can reject the conclusion built on it. An unannounced
# model is a conclusion with an invisible basis.
# 📐 MODEL ONLY WHAT CANNOT BE WRONG, AND ANNOUNCE ALL OF IT. "I would create
# this directory, therefore it exists and is empty" is safe. "There would be
# room" is not.
#
# 🚧 THE THIRD LINE KIND — `WOULD PROBABLY DO`, for a prediction conditional on
# something that cannot be modeled — IS NOT BUILT. Jei has ruled on the first
# two (s79) and NOT on the question underneath the third: whether a degraded
# prediction is MARKED or whether the run STOPS at the first unknown. Both are
# legitimate and the plan's §7.3 says outright to ask before building either.
# ⚠️ Do not add it on inference. → plans/installer-dry-run-s75.md §7.3.
dry::would() {   # text
  printf '  %sWOULD DO:%s %s%s%s\n' "$C_NOTB" "$RESET" "$C_TEXT" "$*" "$RESET"
}
dry::sim() {   # text
  printf '    %sDRY RUN: simulating %s%s\n' "$C_QTXT" "$*" "$RESET"
}

# ── The rehearsal half: "could we do this" ───────────────────────────────────
# ⭐ THE PARENT IS WHAT DECIDES A MKDIR, so that is what gets read — and it is
# the NEAREST EXISTING ancestor, not the literal parent: `mkdir -p a/b/c` under
# an existing `a` is a question about `a`, and asking about `a/b` (which does
# not exist) would answer "not writable" about every deep path.
# ⚠️ IT SAYS "APPEARS", ALWAYS. A writable parent is a strong proxy for a mkdir
# that works, not a proof — quota, immutable flags and LSM denials all sit
# outside it, and a dry run that promises success is one that gets believed once.
dry::nearest_existing() {   # resolved path → the nearest ancestor that exists
  local d=$1
  while [[ -n $d && ! -d $d ]]; do d=${d%/*}; done
  printf '%s' "${d:-/}"
}

# Announce the ASSUMPTION a declined mkdir injects, and rehearse it. Called
# beside a `dry::fs` that would have created the directory, never instead of it:
# one line says what would be done, this one says what the rest of the run is
# now pretending, which are two different claims to two different readers.
dry::dir_sim() {   # spelled resolved
  local p=$1 real=$2 parent
  dry::on || return 0
  parent=$(dry::nearest_existing "$real")
  if [[ -w $parent ]]; then
    dry::sim "$p as existing and empty ($parent appears writable)"
  else
    dry::sim "$p as existing and empty"
    printf '    %s%s does not appear writable, so creating %s may fail%s\n' \
      "$C_NOTB" "$parent" "$p" "$RESET"
  fi
  return 0
}

# ── The modelled directory set — what this run has already said it would make ─
# 🚨 A DRY RUN THAT RE-ASKS IS WRONG, NOT UNSURE, AND THE DIFFERENCE DECIDES THE
# FIX. `ensure_dir` opens with an existence test; under a dry run the directory
# it just announced was never made, so a SECOND question about that same path
# re-reads the filesystem, finds nothing, and asks "Create X?" where a real run
# passes in silence. ⭐ Nothing there is unknowable — the run KNOWS it said it
# would create that path — so the answer is a record the existence test consults,
# not the §4 hedging line kind. (`WOULD PROBABLY DO` is for what CANNOT be
# modeled, Jei has not ruled on it, and this is not a case for it.)
#
# ⭐ IT ANSWERS SILENTLY, ON PURPOSE. A real run prints nothing at the second
# question, so a dry run must not either. The `DRY RUN: simulating …` line was
# already printed beside the FIRST create, which is where the assumption was
# injected; announcing it again would report one assumption twice and invite the
# reader to think two directories were involved.
#
# 🚨 KEYED ON THE SPELLED PATH — NEVER ON AN fs_path RESULT, AND NEVER COMPARED
# WITH `==`. The path spelling contract says an fs_path result is never stored
# and never compared against a stored value, and that two spellings of one
# directory must not read as two places: on a host whose $HOME is reached through
# a link, `~/models` and `/srv/models` are ONE directory and `==` says they are
# two. The recorded spelling is what `ensure_dir` was handed, which is what
# `abs_path` produced, which is what every other path in this program stores.
# ⭐ CONTAINMENT RATHER THAN EQUALITY, AND IT IS EXACT RATHER THAN GENEROUS:
# `mkdir -p` creates every missing ANCESTOR too, so a path that HOLDS a modelled
# path would also be there by now. `path_within child parent` is that question
# with the recorded path as the child, and it already answers equality as well
# ("a directory is within itself here, deliberately").
# ⚠️ AND IT WORKS ON PATHS THAT DO NOT EXIST, WHICH IS THE WHOLE POPULATION HERE:
# both comparators normalize with `realpath -m`, whose documented contract is
# that no component need exist. Measured before this was built — two spellings of
# one absent path compare SAME, an absent path under a symlinked existing
# ancestor compares SAME against its resolved twin, and two genuinely different
# absent paths compare DIFFERENT.
DRY_DIRS=()

dry::modelled() {   # spelled → 0 when this run has already put it there
  local d
  dry::on || return 1
  for d in ${DRY_DIRS[@]+"${DRY_DIRS[@]}"}; do
    path_within "$d" "$1" && return 0
  done
  return 1
}

# Recorded beside the announcement, never instead of it: the WOULD DO line says
# what would be done and this says what the rest of the run may now assume.
# A no-op in a real run, where the kernel is keeping the same record for us.
dry::model_dir() {   # spelled → record a directory this run would have created
  dry::on || return 0
  dry::modelled "$1" && return 0
  DRY_DIRS+=("$1")
  return 0
}

# ── ui_dir_exists — what the UI layer asks instead of `[[ -d ]]` (UI_DIR_EXISTS)
# 🚨 THE SECOND HALF OF THE UI_MKDIR SEAM, AND IT EXISTS FOR THE SAME REASON. The
# layer creates a directory (ui_mkdir) and the layer TESTS for one, and the test
# is exactly as intercept-worthy as the create: a host that models the create
# must model the test, or its own model is invisible to the code that needs it.
# ⭐ Cutting a hole in the layer to call `dry::modelled` from `ensure_dir` would
# cost the property check-installer-layering.sh protects; a fourth declared input
# goes through the seam the layer already has, exactly as UI_MKDIR did in s80.
# ⚠️ A host with no dry run points UI_DIR_EXISTS at something that runs
# `[[ -d $2 ]]`, and the layer never knows the difference.
ui_dir_exists() {   # spelled resolved → 0 when the directory is there, or would be
  [[ -d $2 ]] && return 0
  dry::modelled "$1"
}

# ── ui_mkdir — what the UI layer calls instead of mkdir (the UI_MKDIR seam) ──
# 🚨 THE LAYER MAY NOT CALL dry::fs, AND THAT IS NOT A TECHNICALITY. Its rule 2
# is "the layer never calls back out", check-installer-layering.sh enforces it,
# and Jei's reason for the rule is that the drawing should lift into another
# project of his. A dry-run wrapper reached from inside it would be precisely
# the "single line reaching for a box name because the box name happened to be
# in scope" that the rule's own header warns nobody would notice.
# ⭐ SO THE LAYER CALLS A NAME THE HOST GAVE IT — `"$UI_MKDIR"` — and this is
# droste's answer to that name. A host with no dry run sets UI_MKDIR to
# something that just runs `mkdir -p`, and the layer never knows the difference.
# ⚠️ IT TAKES BOTH SPELLINGS, and the order is the path contract's: the SPELLED
# path is what the user is shown, the RESOLVED one is what the kernel is given.
ui_mkdir() {   # spelled resolved → 0 when the directory is there (or would be)
  local p=$1 real=$2
  dry::fs "create $p" -- mkdir -p "$real" 2>/dev/null || return 1
  dry::model_dir "$p"
  dry::dir_sim "$p" "$real"
  return 0
}

# ── The two choke points ─────────────────────────────────────────────────────
# Usage, both:   dry::fs "<what it would do>" -- <command...>
#                dry::rt "<what it would do>" -- <command...>
#
# In a real run each is a transparent `"$@"`, so the command's own exit status is
# the caller's — the wrapper must never change what a real run does, and the
# suites assert a real run is byte-identical to one without the flag.
# In a dry run each prints its description and returns SUCCESS, because the
# caller's next step has to proceed as though the action had happened; that is
# the modeling §4 describes, and it is why every caller that models a state also
# emits a `dry::sim` line beside it.
#
# 🚨 TWO WRAPPERS AND NOT ONE, THOUGH THEIR BODIES ARE IDENTICAL. They are two
# QUESTIONS, and the checker asks them separately:
#   dry::fs  a user-visible FILESYSTEM mutation — a create, a write, a move, a
#            delete. The irreversible half.
#   dry::rt  a CONTAINER-STATE mutation — pull, create, remove, start, stop, and
#            the systemd units that start boxes at boot.
# ⚠️ READ-ONLY RUNTIME CALLS (`ps`, `inspect`, `is-enabled`, a registry query)
# MUST PASS THROUGH UNWRAPPED, or the dry run stops being able to see the world
# it is describing. Wrapping a read is not a harmless extra safety: it blinds the
# rehearsal, which is the whole point of the feature.
# ⭐ Collapsing them to one name would also cost the checker its only way to say
# WHICH kind of mutation escaped, in the report a maintainer reads at 2am.
dry::fs() {   # description -- command...
  local what=$1
  shift
  [[ ${1-} == -- ]] && shift
  if dry::on; then
    dry::would "$what"
    return 0
  fi
  "$@"
}

dry::rt() {   # description -- command...
  local what=$1
  shift
  [[ ${1-} == -- ]] && shift
  if dry::on; then
    dry::would "$what"
    return 0
  fi
  "$@"
}

# A whole BLOCK a dry run must not enter, where there is no single command to
# wrap — a function that opens a file and writes forty lines into it, a phase
# that drives three of them. The caller says what it would have done and returns.
#
#   dry::skip "would write $f" && return 0
#
# ⚠️ IT IS NOT A WEAKER dry::fs AND MUST NOT BE USED WHERE ONE FITS. The checker
# treats a `dry::skip` as a claim that everything BELOW it in that function is a
# mutation, so using it to guard a block that also READS leaves the dry run
# blind to something it could have reported. Reach for it only when the write is
# the function.
dry::skip() {   # description → 0 when the caller should return without acting
  dry::on || return 1
  dry::would "$*"
  return 0
}
