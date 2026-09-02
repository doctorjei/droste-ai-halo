# ── The box's <box>.cfg: parse + surgical single-line merge (case 2, s59) ────
# THE FILE IS THE USER'S, AND THAT IS THE WHOLE DIFFICULTY. The retired
# `server.env` was droste's outright, so its emitter could truncate and rewrite
# it on every reconfigure. `<box>.cfg` is seeded ONCE by the box (if_missing) and belongs to
# the user from then on: it carries the application's own settings, the user's
# comments and the user's edits. So the installer may only MERGE one line at a
# time, and every other byte must come out exactly as it went in.
#
# 🚨 PARSE, NEVER SOURCE — AND THE SHELL IS NOT THE AUTHORITY. Ruled s60 (Jei:
# "i do not want to mimic sourcing. this is a config file"). The same file IS
# sourced (under `set -a`) a few milliseconds later for the app settings, so
# bash is EVIDENCE about what a shape probably means — never the rule that
# decides. The LAST active assignment wins because later-overrides-earlier is
# what a config file MEANS, not because a sourcing shell happens to agree.
# ⚠️ Two answers here look like they are chosen against bash and are simply the
# rule: an unquoted value's interior spaces are kept whole (a config file does
# not word-split — the value is the text), and text after a closing quote is
# dropped (the value is the quoted span, full stop). A third one IS a chosen
# difference: `NAME= 8188` reads as `8188` where bash would leave the variable
# unset, because that line is an error in the sourcing path and there is no
# reading of a config file under which the user meant anything else.
#
# 🚨 THIS RULE EXISTS TWICE ON PURPOSE, AND THE TWO COPIES MUST NOT DRIFT.
# droste-setup.sh is a standalone `curl | bash` script running on the HOST; it
# cannot source base/resolve/droste-cfg.sh, which lives inside an image. The
# in-box twin is `droste::cfg_get` there, and a DIFFERENTIAL harness feeds one
# fixture corpus to both and asserts identical answers. ⇒ Implement the contract
# in ~/canon/notebook/plans/port-ownership-s47.md ("CASE 2 — P1 CONTRACT")
# LITERALLY rather than cleverly; anything invented here diverges, and the
# divergence is what the differential harness exists to make expensive.
#
# The five settings this is for (the parser itself is parameterised by NAME and
# polices nothing — that restriction belongs to the caller, and the differential
# harness drives arbitrary names):
#
# ⚠️ THE PREFIX IS PER APPLICATION, not a fixed DROSTE_SERVE_ — see BOX_APP:
# DROSTE_COMFYUI_*, DROSTE_LLAMA_*, DROSTE_VLLM_*, DROSTE_DS4_*, and (on the
# finetuning box) DROSTE_JUPYTER_*. cfg_name builds them.
#
#   DROSTE_<APP>_STARTUP_ENABLED   start this box's server when the BOX starts
#   DROSTE_<APP>_HOST              address the server BINDS
#   DROSTE_<APP>_PORT              port it BINDS (host networking: no remap)
#   DROSTE_<APP>_TLS_CERT          PEM certificate path
#   DROSTE_<APP>_TLS_KEY           PEM private key path
#
# ⚠️ THE INSTALLER ONLY ASKS ABOUT TWO OF THEM — STARTUP_ENABLED and PORT — so
# those are the only two it ever writes. The other three are the user's to set
# in the file, and cfg_get reads whatever is there.
#
# ⚠️ NEITHER FUNCTION RESOLVES A PATH SPELLING. Both take the FILE argument as
# the kernel needs it spelled; the caller runs fs_path (the path spelling
# contract: fs_path resolves only at the filesystem boundary, and its result is
# never stored, compared or printed).
#
# ⚠️ THREE ANSWERS THAT LOOK LIKE OVERSIGHTS AND ARE NOT (s60 contract §5). Both
# implementations already agreed on all three, which is exactly WHY they are
# written down — an agreement nobody recorded is the next reader's "fix":
#   1. A BINARY file holding one well-formed line yields that line's value.
#      There is no sniffing and no rejection; the parser reads lines, and a file
#      full of NULs simply has no line that matches.
#   2. A LAST LINE WITH NO TRAILING NEWLINE IS A LINE and is read. ⚠️ cfg_set
#      must not GROW one: a file whose last line lacked a newline still lacks
#      one after some OTHER line of it is rewritten.
#   3. NEITHER cfg_get PRINTS A TRAILING NEWLINE. Callers use `$( )`, where the
#      two would be indistinguishable, so this is stated rather than measured —
#      a later "tidy-up" that added one would be invisible here and visible to
#      the differential harness.

# One human message per distinct problem, at most once per run: cfg_get is
# called once per NAME, so a naive warn gives five identical lines for one
# broken file. STDERR, not warn(): cfg_get's answer is its STDOUT, and a
# message printed there would be read back as part of the value.
CFG_NOTED=""
cfg_note() {  # key message
  local key=${1-} msg=${2-}
  case $'\n'"$CFG_NOTED"$'\n' in
    *$'\n'"$key"$'\n'*) return 0 ;;
  esac
  CFG_NOTED="${CFG_NOTED}${CFG_NOTED:+$'\n'}${key}"
  printf 'droste-setup.sh: %s\n' "$msg" >&2
  return 0
}

# The three parts of an assignment line, set by the two splitters below.
# Globals rather than a subshell: cfg_set needs the value AND the surrounding
# text of one line, and a command substitution would cost a fork per line of the
# file for the privilege of returning one of the four.
CFG_LINE_INDENT=""   # the whitespace before the assignment (or before its `#`)
CFG_LINE_PREFIX=""   # a leading `export` and the whitespace after it, "" if none
CFG_LINE_VALUE=""    # the parsed value: quotes stripped, inline comment removed
CFG_LINE_TAIL=""     # everything the value was followed by, its whitespace included
CFG_LINE_QUOTE=""    # the quote character the value was written with, "" if bare
CFG_LINE_OPEN=0      # 1 when the text ended INSIDE a quote that never closed
CFG_LINE_OPENQ=""    # the quote character that was left open, "" when none was

# 🚨 `export NAME=value` IS AN ASSIGNMENT AND IS ACCEPTED (ruled s59, after the
# in-box twin first excluded it on a strict reading of parse rule 2). Bash sets
# the variable, and the file is still SOURCED for the app settings — so a line
# that works for every other setting while being invisible to the serve settings
# is a split brain in the one file that is supposed to end them. ⚠️ This is the
# most likely divergence point between the two implementations.
# The `export` and the whitespace after it are returned rather than discarded:
# cfg_set puts the line back together and the user's `export` has to survive it.
# Answers through globals, not stdout: a command substitution here would cost a
# fork per line of the file to return a string we already have.
CFG_LINE_BODY=""     # the assignment text with any leading `export ` removed
cfg_take_export() {  # body → CFG_LINE_PREFIX + CFG_LINE_BODY
  local body=$1 rest ws
  CFG_LINE_PREFIX=""
  case $body in
    export[[:space:]]*)
      rest=${body#export}
      ws=${rest%%[![:space:]]*}     # the exact whitespace the user typed
      CFG_LINE_PREFIX="export$ws"
      body=${rest#"$ws"}
      ;;
  esac
  CFG_LINE_BODY=$body
  return 0
}

# Everything to the right of the `=` becomes CFG_LINE_VALUE + CFG_LINE_TAIL.
# Split rather than merely parsed because cfg_set has to put the line back
# together with the user's own trailing documentation still on it.
#
# 🚨 INLINE COMMENTS ARE STRIPPED, AND THAT IS NOT OPTIONAL: every template in
# this project documents a setting on the assignment line itself, and the user
# turns one on by DELETING THE LEADING `#`. That leaves
# `DROSTE_LLAMA_PORT=8080        # port it binds` — which `source` reads as
# `8080` and a take-the-rest-of-the-line parser reads as `8080        # port it
# binds`. The cut is at the first `#` that begins the value or follows
# whitespace.
# ⚠️ Text after a CLOSING quote is dropped: the value IS the quoted span, full
# stop (the only shape that occurs in the wild there is a trailing comment). An
# UNTERMINATED quote keeps its opening quote character, because handing back
# what the user actually typed is what lets an error name the typo.
# ⚠️ IT IS NOT LITERALLY VERBATIM, AND THE MESSAGE MUST NOT CLAIM IT IS (§2c):
# the unterminated text falls through to the UNQUOTED path below, so the inline
# comment cut and the trailing strip both still apply to it. The wording
# "returning the value verbatim" was deleted from the warning for that reason.
# NO ESCAPE PROCESSING AND NO EXPANSION in either form: a `$` comes back
# verbatim and is the caller's problem, never the parser's.
#
# 🚨 THE ORDER OF THE FIRST TWO STEPS IS LOAD-BEARING (contract §1), and the two
# implementations diverge here if it is not followed exactly:
#   1. strip leading whitespace FIRST,
#   2. THEN ask whether the value is quoted.
# `NAME= "a b"` is a QUOTED value. Testing for the quote first classifies it as
# unquoted and hands back the literal text `"a b"` with the quote marks in it.
# ⚠️ The stripped leading whitespace is NOT kept for the rewrite: a value cfg_set
# replaces is re-spelled flush against the `=`. Trailing whitespace IS kept (in
# the TAIL), because that is the alignment between a value and its comment.
#
# ⚠️ THIS FUNCTION NEVER WARNS, and that is deliberate: an unclosed quote may be
# a line continuation (§2), which only the READER can tell, since only the
# reader knows whether another physical line follows. It reports the fact in
# CFG_LINE_OPEN and cfg_note_line turns the final verdict into the message.
cfg_split_rhs() {  # text-after-the-= → sets CFG_LINE_VALUE/TAIL/QUOTE/OPEN
  local raw=${1-} q rest v trail lead
  CFG_LINE_VALUE="" CFG_LINE_TAIL="" CFG_LINE_QUOTE="" CFG_LINE_OPEN=0 CFG_LINE_OPENQ=""
  lead=${raw%%[![:space:]]*}          # step 1; the whole text when it is blank
  case ${raw#"$lead"} in
    '"'*|"'"*)
      rest=${raw#"$lead"}             # step 2, on the STRIPPED text
      q=${rest:0:1}
      rest=${rest:1}
      case $rest in
        *"$q"*)
          # `%%` removes the LONGEST matching suffix, i.e. it cuts at the FIRST
          # closing quote — the one that matches the opening quote.
          CFG_LINE_VALUE=${rest%%"$q"*}
          CFG_LINE_TAIL=${rest#*"$q"}
          CFG_LINE_QUOTE=$q
          return 0
          ;;
      esac
      CFG_LINE_OPEN=1 CFG_LINE_OPENQ=$q
      ;;
  esac
  # Unquoted (or an unterminated quote, which falls through to here on purpose).
  # The comment cut and the trailing strip run on the RAW text rather than the
  # stripped one so that a TAIL still carries the user's own alignment
  # (`NAME=   # note` puts all three spaces back in front of the `#`); the
  # leading whitespace is then taken off the VALUE at the end, which reaches the
  # same answer step 1 would have.
  v=$raw
  case $v in
    # `NAME=#x` is an empty value followed by a comment. The space put in front
    # of it is the one place a TAIL is not returned verbatim, and it is load
    # bearing: without it a replacement would emit `NAME=9000#x`, where the `#`
    # has no whitespace before it and is therefore part of the VALUE — a line
    # that no longer means what it did.
    '#'*)             CFG_LINE_TAIL=" $v"; v="" ;;
    *[[:space:]]'#'*) CFG_LINE_TAIL=${v#"${v%%[[:space:]]'#'*}"}; v=${v%%[[:space:]]'#'*} ;;
  esac
  # The trailing whitespace moves into the TAIL rather than being discarded, so
  # a replacement keeps the user's alignment between the value and its comment.
  # `[[:space:]]` also covers the CR of a file saved with DOS line endings.
  trail=""
  while [[ -n $v && $v != "${v%[[:space:]]}" ]]; do
    trail=${v: -1}$trail
    v=${v%[[:space:]]}
  done
  # Step 1's leading strip, applied last (see the note above) and DISCARDED: a
  # rewritten value goes back flush against the `=`.
  CFG_LINE_VALUE=${v#"${v%%[![:space:]]*}"}
  CFG_LINE_TAIL=$trail$CFG_LINE_TAIL
  return 0
}

# ── §2: `\`-NEWLINE CONTINUATION, INSIDE QUOTES ONLY ─────────────────────────
# 🚨 THE BACKSLASH IS THE ONLY CONTINUATION SIGNAL, AND THAT IS WHAT KEEPS THE
# SCAN BOUNDED. Continuation runs only WHILE each physical line ends with `\`
# and the quote is still open; it never reads ahead speculatively looking for a
# closing quote. So a BLANK line stops it (`NAME="a\` ⏎ ⏎ `b"` is an
# unterminated quote, not `ab`), and an unterminated quote stays exactly the
# error it is instead of swallowing the rest of the file. An unbounded forward
# scan in the healthcheck path is the failure this design refuses.
# ⚠️ The trailing `\` is consumed as the SIGNAL, so it is gone whether or not a
# line follows: `NAME="a\` at EOF reads as `"a`, never `"a\`.
# ⚠️ ANY trailing `\` continues, and EXACTLY ONE character is removed — the last
# one. Anything in front of it is DATA, so `NAME="a\\` ⏎ `b"` is `a\b` and not
# `ab`. No odd/even counting: counting would import the escape semantics this
# contract does not have, where a backslash is a plain character.
# ⚠️ Consequence: A CONTINUED LINE CANNOT END IN A LITERAL BACKSLASH. Put the
# backslash anywhere but the line's last character.
# ⚠️ OUTSIDE a quote there is no continuation at all: `NAME=a\` keeps the
# backslash as part of the value, and cfg_note_line says so.
#
# 🚨 THE TEST IS NAME-BLIND ON PURPOSE. A continued value belonging to some
# OTHER setting swallows its own continuation lines, and one of those lines can
# look exactly like an assignment of the name we are after:
#     DROSTE_LLAMA_NOTE="see \
#     DROSTE_LLAMA_PORT=9000"
# Reading that second line as an assignment would invent a setting out of
# another one's value, so the scan joins logical lines for EVERY name and only
# then asks whether the result is ours.
cfg_line_open() {  # LINE → 0 when the line ends inside a quote that never closed
  local line=$1 body nm
  body=${line#"${line%%[![:space:]]*}"}
  case $body in
    '#'*|'') return 1 ;;                 # a comment is one physical line, always
  esac
  cfg_take_export "$body"; body=$CFG_LINE_BODY
  case $body in
    *=*) ;;
    *)   return 1 ;;
  esac
  nm=${body%%=*}
  [[ $nm =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  # The quote rule lives in ONE place: ask the splitter rather than repeating it.
  # ⚠️ This clobbers the CFG_LINE_* globals, so every caller re-splits the joined
  # line afterwards.
  cfg_split_rhs "${body#*=}"
  [[ $CFG_LINE_OPEN -eq 1 ]]
}

cfg_split_active() {  # NAME LINE → 0 when LINE is an ACTIVE assignment of NAME
  local name=$1 line=$2 indent body
  indent=${line%%[![:space:]]*}          # the whole line when it is all blanks
  body=${line#"$indent"}
  case $body in
    '#'*) return 1 ;;                    # rule 2: a comment, however it is indented
  esac
  cfg_take_export "$body"; body=$CFG_LINE_BODY
  case $body in
    "$name"=*) ;;                        # quoted ⇒ NAME= is matched literally
    *)         return 1 ;;
  esac
  # No whitespace is permitted around the `=`: `FOO = bar` is a COMMAND to bash,
  # not an assignment, and the pattern above already rejects it.
  CFG_LINE_INDENT=$indent
  cfg_split_rhs "${body#"$name"=}"
  return 0
}

# A COMMENTED template line for NAME — `# DROSTE_LLAMA_PORT=8080   # port it
# binds`, which is how every setting ships. cfg_set uncomments it in place so
# the value lands beside its own documentation, which is where the user looks
# for it.
# ⚠️ Exactly ONE leading `#` is stripped, and the whitespace that FOLLOWS it;
# the whitespace that PRECEDED it is the line's indentation and is kept. A prose
# line that merely mentions the name ("# set DROSTE_LLAMA_PORT= to change") does
# not match, because what follows the `#` must start with `NAME=`.
cfg_split_commented() {  # NAME LINE → 0 when LINE is a commented assignment of NAME
  local name=$1 line=$2 indent body
  indent=${line%%[![:space:]]*}
  body=${line#"$indent"}
  case $body in
    '#'*) body=${body#\#} ;;
    *)    return 1 ;;
  esac
  body=${body#"${body%%[![:space:]]*}"}
  cfg_take_export "$body"; body=$CFG_LINE_BODY
  case $body in
    "$name"=*) ;;
    *)         return 1 ;;
  esac
  CFG_LINE_INDENT=$indent
  cfg_split_rhs "${body#"$name"=}"
  return 0
}

# ── The line reader, shared by cfg_get and cfg_set ───────────────────────────
# The whole file is slurped rather than streamed because BOTH callers need it:
# cfg_set has always needed the array to rebuild the file, and since §2 a
# LOGICAL line can span several physical ones, so the reader has to be able to
# look at the next line. One reader, one grouping rule, no parallel path — the
# two functions cannot disagree about where an assignment ends.
CFG_LINES=()         # the file's physical lines, in order
CFG_NONL=0           # 1 when the last physical line had no newline after it
cfg_read_lines() {   # FILE → CFG_LINES + CFG_NONL
  local file=$1 line rc
  CFG_LINES=(); CFG_NONL=0
  while :; do
    rc=0; IFS= read -r line || rc=$?
    if [[ $rc -ne 0 && -z $line ]]; then break; fi
    CFG_LINES+=("$line")
    # A final line with no newline after it: it is a line, and it must not GROW
    # one just because we touched a different line of the file.
    [[ $rc -eq 0 ]] || { CFG_NONL=1; break; }
  done < "$file"
  return 0
}

# One LOGICAL line, starting at physical index i. CFG_LOGICAL_END is the index
# of the LAST physical line it consumed — which is what lets cfg_set replace all
# N of them together instead of leaving orphaned continuation lines behind as
# live junk (the C `//`-comment-ending-in-`\` failure: a writer that cannot tell
# where an assignment ends).
CFG_LOGICAL=""
CFG_LOGICAL_END=0
cfg_join_at() {  # index → CFG_LOGICAL + CFG_LOGICAL_END
  local i=$1 n=${#CFG_LINES[@]} text
  text=${CFG_LINES[i]}
  while cfg_line_open "$text"; do
    case $text in
      *\\) ;;                        # ends with `\` ⇒ the line asks to continue
      *)   break ;;                  # anything else ends the scan, blank included
    esac
    text=${text%\\}                 # the signal is consumed either way (§2b)
    [[ $((i + 1)) -lt $n ]] || break   # EOF: the quote stays unterminated
    text=$text${CFG_LINES[i + 1]}   # the next line RAW: no strip, no comment cut
    i=$((i + 1))
  done
  CFG_LOGICAL=$text
  CFG_LOGICAL_END=$i
  return 0
}

# The diagnostics a line owes once its LOGICAL form is final. Called only by
# cfg_get and only for a line that actually assigns NAME: a message about a line
# that turned out to be a continuation, or about some other setting entirely,
# would be noise about text we were not asked to read.
# ⚠️ cfg_set does NOT call this. Its own first act is a cfg_get over the same
# file for the same name, so everything here has already been said.
cfg_note_line() {  # NAME → 0, having said whatever this line earns
  local name=$1
  if [[ $CFG_LINE_OPEN -eq 1 ]]; then
    cfg_note "unterminated:$name" \
      "unterminated $CFG_LINE_OPENQ quote in $name $EMD check the quoting in your config file"
    return 0
  fi
  # Only an UNQUOTED value can be caught out by this: inside quotes the
  # backslash would have continued the line.
  if [[ -z $CFG_LINE_QUOTE && $CFG_LINE_VALUE == *\\ ]]; then
    cfg_note "backslash:$name" \
      "$name ends with a backslash $EMD line continuation only works inside quotes, so the backslash is part of the value"
  fi
  return 0
}

# ── cfg_get — THE READ ENTRY POINT (installer half of the shared contract) ───
# Usage:  value=$(cfg_get DROSTE_LLAMA_PORT "$file")
#
# Prints the value (possibly empty) on stdout and ALWAYS EXITS 0. Empty output
# means "absent" — rule 5: a blank value is treated exactly as absent, so blank
# means "no opinion" and the caller applies droste's per-box default.
# ⚠️ NO TRAILING NEWLINE, matching droste::cfg_get byte for byte. Callers use a
# command substitution, where the two would be indistinguishable; the
# differential harness may not.
#
# 🚨 THE LAST ACTIVE ASSIGNMENT WINS, so the scan cannot stop early.
# 🚨 NEVER FAILS, NEVER ABORTS THE CALLER. A missing, unreadable, non-regular or
# malformed file yields "absent" for every name. A box with no config file yet
# is a NORMAL state and is silent; only a file that exists and cannot be read
# earns a message.
cfg_get() {  # NAME FILE → the value on stdout, always 0
  local name=${1-} file=${2-} out="" i n
  if [[ -z $name || -z $file ]]; then printf '%s' ''; return 0; fi
  # NAME is used inside a glob pattern below, so a metacharacter in it would
  # match lines it has no business matching — and a name that is not a variable
  # name cannot be an assignment of anything, so the honest answer is "absent".
  if [[ ! $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    cfg_note "badname:$name" "'$name' is not a valid variable name $EMD treating it as unset"
    printf '%s' ''; return 0
  fi
  # -f excludes a directory (whose redirect would fail) and a FIFO (whose
  # redirect would BLOCK, with no timeout available here).
  if [[ ! -f $file ]]; then printf '%s' ''; return 0; fi
  if [[ ! -r $file ]]; then
    cfg_note "unreadable:$file" \
      "cannot read $file $EMD every setting in it reads as unset; check its permissions"
    printf '%s' ''; return 0
  fi
  cfg_read_lines "$file"
  n=${#CFG_LINES[@]}
  # The walk steps over LOGICAL lines: `i` advances past every physical line a
  # continued assignment consumed, so a continuation line can never be read as
  # an assignment of its own.
  for (( i = 0; i < n; )); do
    cfg_join_at "$i"
    if cfg_split_active "$name" "$CFG_LOGICAL"; then
      out=$CFG_LINE_VALUE
      cfg_note_line "$name"
    fi
    i=$((CFG_LOGICAL_END + 1))
  done
  printf '%s' "$out"
  return 0
}

# ── cfg_set — THE MERGE (installer only; the box never writes this file) ─────
# Usage:  cfg_set DROSTE_LLAMA_PORT 8080 "$file"
# 0 on success INCLUDING the no-op; 1 when the file could not be written or does
# not exist, and in either case the original is exactly as it was.
#
# Placement, in order: replace the LAST ACTIVE assignment in place (position and
# indentation preserved) · else uncomment the LAST COMMENTED template line for
# that name in place · else append to the END of the file.
# ⚠️ "Append" appends INSIDE AN EXISTING FILE. A missing file is refused (see
# below) — the append branch may never become a create.
#
# 🚨 IF THE PARSED VALUE ALREADY EQUALS THE VALUE TO WRITE, NOTHING HAPPENS AT
# ALL — not a rewrite that happens to produce the same bytes. Byte-identical
# file, unchanged mtime. It is the strongest anti-clobber property available: a
# modify run that does not change the port does not touch the user's file.
# 🚨 TEMP FILE + RENAME, NEVER IN PLACE, AND NEVER A TRUNCATE (s57: a guard can
# corrupt what it guards). Everything the user wrote survives.
#
# 🚨 DUPLICATE ACTIVE ASSIGNMENTS: WRITE THE LAST, TOUCH NEITHER (contract §4).
# The earlier lines are left EXACTLY as the user wrote them — commenting them
# out was proposed and rejected, because that edits a line the user wrote and
# the file is theirs. We warn and stay consistent with our own parse rule; we do
# not tidy. ⚠️ The file then keeps showing two live lines for one setting. The
# user created that state and can see it; it is not a defect to re-raise.
#
# 🚨 A CONTINUED ASSIGNMENT IS ONE LOGICAL ASSIGNMENT SPANNING N PHYSICAL LINES,
# AND ALL N ARE CONSUMED. Replacing only the first would leave the rest of the
# value behind as live junk — the C `//`-comment-ending-in-`\` failure.
# ⚠️ A genuine value change therefore REFLOWS the assignment onto one line. That
# is an accepted loss, recorded so it is not rediscovered as a bug: continuation
# exists for the look, but preserving a wrap around a value the user just
# changed is worse guesswork. Idempotence protects the common case — an
# unchanged value writes nothing at all, so the user's wrapping survives
# byte-identical.
cfg_set() {  # NAME VALUE FILE → 0 written or unchanged, 1 not written
  local cur i n target=-1 tend=-1 mode="" dups=0 nonl=0 tmp dir text last new
  local name=${1-} value=${2-} file=${3-}

  if [[ -z $file ]]; then
    warn "cfg_set: no config file given for $name"; return 1
  fi
  if [[ ! $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    warn "cfg_set: '$name' is not a shell variable name $EMD nothing written"; return 1
  fi
  # 🚨 A FILE THAT IS NOT THERE IS A REFUSAL, NEVER A CREATE. <box>.cfg is seeded
  # if_missing by apply_templates.py at the box's FIRST CONTAINER START, and that
  # seeding is SKIPPED when the destination already exists. So a cfg_set that
  # appended into a missing path would leave a five-line stub that PERMANENTLY
  # BLOCKS the seed: the user gets a config file holding the serve settings and
  # none of the several hundred documented app settings, with nothing failing and
  # nothing warning. The install order (create → start, which seeds → cfg_set →
  # restart) is what makes this case impossible; this refusal is what makes the
  # ordering a guarantee rather than a convention the next caller can break.
  if [[ ! -e $file ]]; then
    warn "$file does not exist yet $EMD the box seeds it at its first start, so $name was not recorded"
    return 1
  fi
  # An EXISTING file we cannot read is a refusal too, not an overwrite:
  # rebuilding from a read that returned nothing would truncate the user's config.
  if [[ ! -f $file ]]; then
    warn "$file is not a regular file $EMD leaving it alone"; return 1
  fi
  if [[ ! -r $file ]]; then
    warn "cannot read $file $EMD refusing to rewrite a file we cannot see"; return 1
  fi

  cur=$(cfg_get "$name" "$file")

  cfg_read_lines "$file"
  n=${#CFG_LINES[@]} nonl=$CFG_NONL

  # Both scans walk LOGICAL lines (see cfg_join_at): `target` is where the
  # assignment starts and `tend` the last physical line it owns, so a continued
  # assignment is replaced whole. A commented line is never open, so a template
  # line is always exactly one physical line.
  # ⚠️ THE SPAN IS EXACTLY WHAT THE PARSER CONSUMED, and the edge case is ruled
  # (§2d): a blank line that STOPPED a continuation was still consumed by the
  # join, so it belongs to the assignment and goes with it. The alternative —
  # a writer whose idea of the span differs from the parser's by one line — is
  # the orphaned-junk failure by another route. Do not "fix" this.
  for (( i = 0; i < n; )); do
    cfg_join_at "$i"
    if cfg_split_active "$name" "$CFG_LOGICAL"; then
      target=$i; tend=$CFG_LOGICAL_END; mode=active; dups=$((dups + 1))
    fi
    i=$((CFG_LOGICAL_END + 1))
  done

  # §4: the user's file contradicts itself. Say so, write the last assignment,
  # and leave the earlier lines exactly as they are.
  # 🚨 THIS SITS ABOVE THE NO-OP SHORT-CIRCUIT ON PURPOSE (§4a): a duplicate is a
  # property of the USER'S FILE, not of our write, so whether we ended up
  # changing anything has no bearing on whether they should be told. Reporting a
  # condition and modifying a file are different acts, and the no-op promises
  # only the second — byte-identical file, unchanged mtime, message still said.
  # ⚠️ STDOUT, via the installer's own warn(): cfg_set's stdout is UI. Only
  # cfg_get owes its diagnostics to stderr, and only because ITS stdout is the
  # value being returned.
  if [[ $dups -gt 1 ]]; then
    warn "$name is assigned more than once in $file $EMD the last assignment wins; the earlier one was left as you wrote it"
  fi

  if [[ $cur == "$value" ]]; then return 0; fi

  if [[ $target -lt 0 ]]; then
    for (( i = 0; i < n; )); do
      cfg_join_at "$i"
      if cfg_split_commented "$name" "$CFG_LOGICAL"; then
        target=$i; tend=$CFG_LOGICAL_END; mode=commented
      fi
      i=$((CFG_LOGICAL_END + 1))
    done
  fi

  # Re-split the CHOSEN line: the loops above ran past it, so the globals hold
  # the last line they looked at rather than the last line that matched.
  if [[ $mode == active ]]; then
    cfg_join_at "$target"; cfg_split_active "$name" "$CFG_LOGICAL" || :
  elif [[ $mode == commented ]]; then
    cfg_join_at "$target"; cfg_split_commented "$name" "$CFG_LOGICAL" || :
  else
    CFG_LINE_INDENT="" CFG_LINE_PREFIX="" CFG_LINE_TAIL="" CFG_LINE_QUOTE=""
  fi
  if ! cfg_quote "$value" "$CFG_LINE_QUOTE"; then
    warn "cannot record $name in $file $EMD the value mixes quote characters"; return 1
  fi
  new="$CFG_LINE_INDENT$CFG_LINE_PREFIX$name=$CFG_QUOTED$CFG_LINE_TAIL"

  dir=$(dirname "$file")
  tmp=$(mktemp "$dir/.droste-cfg.XXXXXX" 2>/dev/null) || {
    warn "could not write in $dir $EMD $name was not recorded in $file"; return 1; }
  {
    for (( i = 0; i < n; )); do
      # `last` is the physical line this iteration emits THROUGH: for the target
      # that is the end of its continuation span, and the N lines it covered
      # collapse into the one rebuilt line.
      if [[ $i -eq $target ]]; then text=$new; last=$tend; else text=${CFG_LINES[i]}; last=$i; fi
      if [[ $nonl -eq 1 && $last -eq $((n - 1)) && $target -ge 0 ]]; then
        printf '%s' "$text"
      else
        printf '%s\n' "$text"
      fi
      i=$((last + 1))
    done
    # Appending terminates a final unterminated line first — the alternative is
    # gluing our assignment onto the end of the user's last one.
    [[ $target -ge 0 ]] || printf '%s\n' "$new"
  } > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || :
    warn "could not write $tmp $EMD $name was not recorded in $file"; return 1; }

  # The user's own mode, not mktemp's 0600: this file is read inside the box,
  # and a merge must not change who can read it.
  chmod --reference="$file" "$tmp" 2>/dev/null || :
  mv -f "$tmp" "$file" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || :
    warn "could not replace $file $EMD $name was not recorded"; return 1; }
  return 0
}

# How a value is spelled on the line. Set by cfg_quote.
CFG_QUOTED=""
# The written form has to survive OUR OWN parser unchanged — that is the whole
# test, and it is why the bare set excludes `#` (a whitespace-preceded `#` opens
# a comment), whitespace, and `~` (which the sourcing shell would expand,
# early-binding a late-bound reference — the s35 lesson).
# SINGLE quotes are the default wrapper because the sourcing shell performs no
# expansion inside them: a `$` in a path then reaches the app as the user typed
# it, which is what the path spelling contract asks for.
# ⚠️ A value carrying BOTH a single quote and a `$`/backtick/backslash/double
# quote has NO representation under a contract that strips one outer pair and
# processes no escapes. That is a refusal (1), not a silently mangled file.
cfg_quote() {  # VALUE [PREFERRED-QUOTE] → 0 + CFG_QUOTED, 1 when unrepresentable
  local v=${1-} pref=${2-}
  CFG_QUOTED=""
  # The preferred quote is the one the line already used: a user who quoted
  # their path keeps their quotes.
  if [[ $pref == "'" && $v != *"'"* ]]; then CFG_QUOTED="'$v'"; return 0; fi
  if [[ $pref == '"' && $v != *['"$`\']* ]]; then CFG_QUOTED="\"$v\""; return 0; fi
  if [[ $v =~ ^[A-Za-z0-9_@%+=:,./-]*$ ]]; then CFG_QUOTED=$v; return 0; fi
  if [[ $v != *"'"* ]]; then CFG_QUOTED="'$v'"; return 0; fi
  if [[ $v != *['"$`\']* ]]; then CFG_QUOTED="\"$v\""; return 0; fi
  return 1
}

