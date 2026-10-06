#!/usr/bin/env bash
#
# gam-bulk-drivefileacl.sh
#
# Bulk-grant Drive file access across multiple documents that have different owners.
# For each CSV row it runs:
#
#   <gam-instance> user <owner_email> add drivefileacl <document_id> user <target_user> role <role>
#
# TENANT SAFETY
#   Defaults to the "gamcl" (Clover) instance. It will NOT silently fall back to a
#   bare "gam" -- running Drive ACL changes against the wrong tenant is worse than
#   not running at all. Override deliberately with --gam or GAM_BIN.
#
# SHELL FUNCTION SUPPORT
#   gamcl / gamcph are zsh *functions* defined in ~/.zshrc. Functions are not
#   inherited by scripts, so this script re-sources your zshrc inside zsh and calls
#   the function there -- using the exact definition your interactive shell uses.
#
# NOTIFICATION EMAIL
#   Standard GAM7 uses a BARE "sendemail" keyword to send notification mail, and
#   sends nothing when the keyword is absent. It rejects "sendemail false" with
#   "ERROR: Invalid argument". GAMADV-XTD3 instead takes "sendemail <Boolean>".
#   Default here: omit the keyword entirely (no notification) -- valid on both.
#   With --sendemail, the correct form is auto-detected from the GAM flavor.
#
# Usage:
#   ./gam-bulk-drivefileacl.sh grants.csv                       # gamcl (Clover)
#   ./gam-bulk-drivefileacl.sh --dry-run grants.csv
#   ./gam-bulk-drivefileacl.sh --expect-domain cloverhealth.com grants.csv
#   ./gam-bulk-drivefileacl.sh --gam gamcph --expect-domain counterparthealth.com grants.csv
#
# CSV format (header row required, column order does not matter):
#   owner_email,document_id,target_user,role
#
# Valid roles: reader, writer, commenter, owner, organizer, fileorganizer
# ("viewer" is accepted and mapped to "reader")

set -uo pipefail

# ---- Defaults -------------------------------------------------------------
DEFAULT_GAM="gamcl"                 # Clover instance -- deliberate default
GAM_BIN="${GAM_BIN:-$DEFAULT_GAM}"
GAM_EXPLICIT=0
ZSHRC="${ZSHRC:-$HOME/.zshrc}"
FORCE_MODE=""                       # "", "func", or "binary"
DRY_RUN=0
SEND_EMAIL=0
SENDEMAIL_SYNTAX="auto"             # auto | bare | boolean
EXPECT_DOMAIN=""
SKIP_PREFLIGHT=0
ASSUME_YES=0
LOG_FILE=""
CSV_FILE=""

GAM_SEARCH_DIRS=(
  "$HOME/bin" "$HOME/.local/bin" "/usr/local/bin" "/opt/homebrew/bin"
  "$HOME/gam" "$HOME/gam7" "$HOME/bin/gam7" "$HOME/bin/gamadv-xtd3"
)

usage() {
  cat <<'EOF'
Usage: gam-bulk-drivefileacl.sh [options] <csv-file>

Tenant / instance selection:
  --gam <name|path>      GAM instance: a zsh function name (gamcl, gamcph), a command
                         on PATH, or an absolute path to the gam binary.
                         Default: gamcl (Clover).
  --expect-domain <dom>  Abort unless the instance reports this primary domain.
                         Strongly recommended for unattended/scheduled runs.
  --zshrc <path>         Where to find your zsh function definitions (default ~/.zshrc).
  --func | --binary      Force shell-function or direct-binary mode.
  --skip-preflight       Skip tenant verification (not advised).
  --yes                  Auto-confirm the tenant prompt.

Behaviour:
  --dry-run              Print the commands without executing them
  --sendemail            Send Drive notification mail to the target (default: off).
                         Correct syntax is auto-detected per GAM flavor.
  --sendemail-syntax <s> Force notification syntax: bare | boolean
                         (bare = GAM7 "sendemail"; boolean = XTD3 "sendemail true")
  --log <file>           Append a timestamped result line for every row
  -h, --help             Show this help

CSV columns (header required): owner_email,document_id,target_user,role
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)          DRY_RUN=1; shift ;;
    --sendemail)        SEND_EMAIL=1; shift ;;
    --no-sendemail)     SEND_EMAIL=0; shift ;;
    --sendemail-syntax) SENDEMAIL_SYNTAX="${2:-auto}"; shift 2 ;;
    --log)              LOG_FILE="${2:-}"; shift 2 ;;
    --gam)              GAM_BIN="${2:-}"; GAM_EXPLICIT=1; shift 2 ;;
    --zshrc)            ZSHRC="${2:-}"; shift 2 ;;
    --func)             FORCE_MODE="func"; shift ;;
    --binary)           FORCE_MODE="binary"; shift ;;
    --expect-domain)    EXPECT_DOMAIN="${2:-}"; shift 2 ;;
    --skip-preflight)   SKIP_PREFLIGHT=1; shift ;;
    --yes|-y)           ASSUME_YES=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    -*)                 echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *)                  CSV_FILE="$1"; shift ;;
  esac
done

case "$SENDEMAIL_SYNTAX" in
  auto|bare|boolean) ;;
  *) echo "Error: --sendemail-syntax must be 'bare' or 'boolean'." >&2; exit 2 ;;
esac

# ---- Input validation (before anything that touches a tenant) -------------
if [[ -z "$CSV_FILE" ]]; then
  echo "Error: no CSV file supplied." >&2; usage; exit 2
fi
if [[ ! -r "$CSV_FILE" ]]; then
  echo "Error: cannot read CSV file '$CSV_FILE'." >&2; exit 2
fi

# ---- Resolve the GAM instance ---------------------------------------------
GAM_MODE=""
GAM_RESOLVED=""

is_zsh_function() {
  local name="$1"
  [[ -n "$name" && "$name" != */* ]] || return 1
  [[ -r "$ZSHRC" ]] || return 1
  command -v zsh >/dev/null 2>&1 || return 1
  zsh -c "source '$ZSHRC' >/dev/null 2>&1; typeset -f -- '$name' >/dev/null 2>&1" 2>/dev/null
}

resolve_binary() {
  local candidate="$1" d
  candidate="${candidate%/}"

  if [[ "$candidate" == */* || "$candidate" == /* ]]; then
    if [[ -d "$candidate" ]]; then
      # A directory was passed (e.g. ~/bin/gam7); the binary is usually <dir>/gam.
      if [[ -f "$candidate/gam" && -x "$candidate/gam" ]]; then
        GAM_RESOLVED="$candidate/gam"; return 0
      fi
      echo "Note: '$candidate' is a directory with no executable 'gam' inside." >&2
      return 1
    fi
    [[ -f "$candidate" && -x "$candidate" ]] && { GAM_RESOLVED="$candidate"; return 0; }
    return 1
  fi

  if command -v "$candidate" >/dev/null 2>&1; then
    local p; p="$(command -v "$candidate")"
    [[ -f "$p" && -x "$p" ]] && { GAM_RESOLVED="$p"; return 0; }
  fi

  for d in "${GAM_SEARCH_DIRS[@]}"; do
    [[ -f "$d/$candidate" && -x "$d/$candidate" ]] && { GAM_RESOLVED="$d/$candidate"; return 0; }
    [[ -f "$d/$candidate/gam" && -x "$d/$candidate/gam" ]] && { GAM_RESOLVED="$d/$candidate/gam"; return 0; }
  done
  return 1
}

case "$FORCE_MODE" in
  func)
    if is_zsh_function "$GAM_BIN"; then GAM_MODE="func"; GAM_RESOLVED="$GAM_BIN"
    else echo "Error: --func given but '$GAM_BIN' is not a function in $ZSHRC." >&2; exit 2; fi ;;
  binary)
    if resolve_binary "$GAM_BIN"; then GAM_MODE="binary"
    else echo "Error: --binary given but '$GAM_BIN' is not an executable file." >&2; exit 2; fi ;;
  *)
    if is_zsh_function "$GAM_BIN"; then
      GAM_MODE="func"; GAM_RESOLVED="$GAM_BIN"
    elif resolve_binary "$GAM_BIN"; then
      GAM_MODE="binary"
    fi ;;
esac

if [[ -z "$GAM_MODE" ]]; then
  cat >&2 <<EOF
Error: could not resolve GAM instance '$GAM_BIN'.

Checked:
  - zsh function defined in: $ZSHRC $( [[ -r "$ZSHRC" ]] && echo "(readable)" || echo "(NOT READABLE)" )
  - executable file on PATH and in common install dirs

This script will NOT fall back to a generic 'gam'.

Diagnose with:
  type $GAM_BIN
  zsh -c "source $ZSHRC >/dev/null 2>&1; typeset -f $GAM_BIN"

If the function lives elsewhere (~/.zprofile, a sourced aliases file), use:
  --zshrc /path/to/that/file
EOF
  exit 2
fi

gam_run() {
  if [[ "$GAM_MODE" == "func" ]]; then
    zsh -c 'source "$1" >/dev/null 2>&1; shift; "$@"' zsh "$ZSHRC" "$GAM_RESOLVED" "$@"
  else
    "$GAM_RESOLVED" "$@"
  fi
}

gam_display() {
  if [[ "$GAM_MODE" == "func" ]]; then echo "$GAM_RESOLVED (zsh function from $ZSHRC)"
  else echo "$GAM_RESOLVED"; fi
}

echo "GAM instance : $(gam_display)"
[[ $GAM_EXPLICIT -eq 0 ]] && echo "               (default '$DEFAULT_GAM' -- Clover)"

# ---- Notification syntax --------------------------------------------------
# Only relevant when --sendemail is requested. Default omits the keyword, which
# is the "no notification" behaviour on every GAM flavor.
SENDEMAIL_ARGS=()

detect_sendemail_syntax() {
  local ver
  ver="$(gam_run version 2>&1 | head -5)"
  if printf '%s' "$ver" | grep -qi 'xtd3\|advanced'; then
    echo "boolean"
  else
    echo "bare"
  fi
}

if [[ $SEND_EMAIL -eq 1 ]]; then
  syn="$SENDEMAIL_SYNTAX"
  if [[ "$syn" == "auto" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then syn="bare"; else syn="$(detect_sendemail_syntax)"; fi
  fi
  if [[ "$syn" == "boolean" ]]; then SENDEMAIL_ARGS=(sendemail true)
  else SENDEMAIL_ARGS=(sendemail); fi
  echo "Notification : ON (${SENDEMAIL_ARGS[*]})"
else
  echo "Notification : off (keyword omitted)"
fi

# ---- Preflight: confirm which tenant we are actually pointed at -----------
preflight() {
  local info domain customer
  if ! info="$(gam_run info domain 2>&1)"; then
    echo "Error: '$(gam_display) info domain' failed. Is this instance configured/authorized?" >&2
    echo "--- output ---" >&2; echo "$info" >&2; echo "--------------" >&2
    if [[ "$GAM_MODE" == "binary" ]]; then
      echo "Hint: if this instance normally runs as a shell function (gamcl/gamcph)," >&2
      echo "      calling the bare binary skips the env/config that function sets." >&2
      echo "      Try:  --gam gamcl" >&2
    fi
    exit 2
  fi

  domain="$(printf '%s\n' "$info" \
            | grep -iE '^[[:space:]]*(primary domain|domain):' \
            | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')"
  customer="$(printf '%s\n' "$info" \
            | grep -iE 'customer id' \
            | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '\r')"

  [[ -z "$domain" ]] && domain="(could not parse)"
  echo "Primary domain: $domain"
  [[ -n "$customer" ]] && echo "Customer ID   : $customer"

  if [[ -n "$EXPECT_DOMAIN" ]]; then
    if [[ "$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')" \
       != "$(printf '%s' "$EXPECT_DOMAIN" | tr '[:upper:]' '[:lower:]')" ]]; then
      echo "ABORT: expected domain '$EXPECT_DOMAIN' but instance reports '$domain'." >&2
      exit 3
    fi
    echo "Domain check  : OK (matches --expect-domain $EXPECT_DOMAIN)"
    return 0
  fi

  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    echo "ABORT: running non-interactively without --expect-domain or --yes." >&2
    echo "Add --expect-domain <domain> so the tenant is verified, not assumed." >&2
    exit 3
  fi
  read -r -p "Proceed against '$domain'? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

if [[ $SKIP_PREFLIGHT -eq 1 ]]; then
  echo "Preflight     : SKIPPED (--skip-preflight)"
else
  preflight
fi
echo

log_line() {
  [[ -n "$LOG_FILE" ]] && printf '%s [%s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$GAM_RESOLVED" "$1" >> "$LOG_FILE"
  return 0
}
log_line "RUN start gam=$GAM_RESOLVED mode=$GAM_MODE csv=$CSV_FILE dry_run=$DRY_RUN expect_domain=${EXPECT_DOMAIN:-none} sendemail=${SENDEMAIL_ARGS[*]:-none}"

clean() {
  printf '%s' "$1" \
    | sed -e $'s/^\xEF\xBB\xBF//' -e 's/\r$//' \
          -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"//' -e 's/"$//'
}

normalize_role() {
  local r; r="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$r" in
    viewer|view|read)  echo "reader" ;;
    write|editor|edit) echo "writer" ;;
    comment)           echo "commenter" ;;
    *)                 echo "$r" ;;
  esac
}

VALID_ROLES=" reader writer commenter owner organizer fileorganizer "

# ---- Parse header so column order does not matter -------------------------
IFS= read -r header_line < "$CSV_FILE"
header_line="${header_line%$'\r'}"

col_owner=-1; col_doc=-1; col_target=-1; col_role=-1
idx=0
IFS=',' read -ra HEADERS <<< "$header_line"
for h in "${HEADERS[@]}"; do
  key="$(clean "$h" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')"
  case "$key" in
    owneremail|owner)                 col_owner=$idx ;;
    documentid|docid|fileid|document) col_doc=$idx ;;
    targetuser|target|grantee|user)   col_target=$idx ;;
    role|roletype)                    col_role=$idx ;;
  esac
  idx=$((idx+1))
done

missing=""
[[ $col_owner  -lt 0 ]] && missing+=" owner_email"
[[ $col_doc    -lt 0 ]] && missing+=" document_id"
[[ $col_target -lt 0 ]] && missing+=" target_user"
[[ $col_role   -lt 0 ]] && missing+=" role"
if [[ -n "$missing" ]]; then
  echo "Error: CSV header is missing required column(s):$missing" >&2
  echo "Expected header: owner_email,document_id,target_user,role" >&2
  exit 2
fi

# ---- Process rows ---------------------------------------------------------
total=0; ok=0; failed=0; skipped=0
declare -a FAILURES=()

row_no=1
while IFS= read -r line || [[ -n "$line" ]]; do
  row_no=$((row_no+1))
  line="${line%$'\r'}"
  [[ -z "${line//,/}" ]] && continue
  [[ "${line:0:1}" == "#" ]] && continue

  IFS=',' read -ra F <<< "$line"
  owner="$(clean "${F[$col_owner]:-}")"
  docid="$(clean "${F[$col_doc]:-}")"
  target="$(clean "${F[$col_target]:-}")"
  role="$(normalize_role "$(clean "${F[$col_role]:-}")")"

  total=$((total+1))

  if [[ -z "$owner" || -z "$docid" || -z "$target" || -z "$role" ]]; then
    echo "Row $row_no: SKIPPED - missing a required value (owner='$owner' doc='$docid' target='$target' role='$role')" >&2
    log_line "SKIP row=$row_no reason=missing-field"
    skipped=$((skipped+1)); continue
  fi

  if [[ "$VALID_ROLES" != *" $role "* ]]; then
    echo "Row $row_no: SKIPPED - invalid role '$role' (valid: reader writer commenter owner organizer fileorganizer)" >&2
    log_line "SKIP row=$row_no reason=invalid-role role=$role"
    skipped=$((skipped+1)); continue
  fi

  args=(user "$owner" add drivefileacl "$docid" user "$target" role "$role")
  [[ ${#SENDEMAIL_ARGS[@]} -gt 0 ]] && args+=("${SENDEMAIL_ARGS[@]}")

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $GAM_RESOLVED ${args[*]}"
    log_line "DRYRUN row=$row_no ${args[*]}"
    ok=$((ok+1)); continue
  fi

  if output="$(gam_run "${args[@]}" 2>&1)"; then
    echo "Successfully granted $role access to $target"
    log_line "OK row=$row_no owner=$owner doc=$docid target=$target role=$role"
    ok=$((ok+1))
  else
    echo "FAILED: could not grant $role access to $target on $docid (owner $owner)" >&2
    [[ -n "$output" ]] && echo "  gam said: ${output//$'\n'/ | }" >&2
    log_line "FAIL row=$row_no owner=$owner doc=$docid target=$target role=$role msg=${output//$'\n'/ | }"
    FAILURES+=("row $row_no: $target on $docid (owner $owner)")
    failed=$((failed+1))
  fi
done < <(tail -n +2 "$CSV_FILE")

# ---- Summary --------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Instance : $(gam_display)"
echo "Processed: $total   Succeeded: $ok   Failed: $failed   Skipped: $skipped"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
echo "----------------------------------------"
log_line "RUN end processed=$total ok=$ok failed=$failed skipped=$skipped"

[[ $failed -gt 0 ]] && exit 1
exit 0
