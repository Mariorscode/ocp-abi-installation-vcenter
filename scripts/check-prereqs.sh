#!/usr/bin/env bash
# Shared helper library + standalone prerequisite checker.
#
# Two ways to use it:
#   1. Standalone  : scripts/check-prereqs.sh        -> checks every tool the repo can need
#   2. Sourced     : source scripts/check-prereqs.sh -> gives you the colour/log helpers
#                    and require_tools(), so install.sh / add-nodes.sh don't each
#                    reimplement their own tool checking.
#
# Sourcing it does NOT run any checks and does NOT change the caller's shell
# options - it only defines functions and colour variables.


# ==========================================
#  Colours (auto-disabled when not a TTY)
# ==========================================

# Honour NO_COLOR (https://no-color.org/) and skip escape codes when stdout
# isn't a terminal, so piping/redirecting output stays clean.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_CYAN=$'\033[0;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi


# ==========================================
#  Console output helpers
# ==========================================

# Big banner shown once at the start of a script.
say_banner() {
  printf '\n%s%s╭─────────────────────────────────────────────────────────────╮%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '%s%s│%s %-59s %s%s│%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$1" "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '%s%s╰─────────────────────────────────────────────────────────────╯%s\n\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
}

# Numbered top-level step, e.g. say_step 2 6 "Creating VMs"
say_step() {
  printf '\n%s%s▸ [%s/%s]%s %s%s%s\n' "$C_BOLD" "$C_BLUE" "$1" "$2" "$C_RESET" "$C_BOLD" "$3" "$C_RESET"
}

say_ok()    { printf '  %s✓%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
say_info()  { printf '  %s•%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
say_warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
say_dim()   { printf '  %s%s%s\n'   "$C_DIM"    "$*"       "$C_RESET"; }

# Print an error and abort. Use for every fatal condition so the formatting
# (and exit code) stays consistent across scripts.
die() {
  printf '\n%s%s✗ ERROR:%s %s\n\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

say_success() {
  printf '\n%s%s✓ %s%s\n\n' "$C_BOLD" "$C_GREEN" "$*" "$C_RESET"
}


# ==========================================
#  Tool checking
# ==========================================

# Install hint per tool, kept in one place so both the standalone report and
# the require_tools() failure message say the same thing.
tool_hint() {
  case "$1" in
    govc)              echo "vSphere CLI - https://github.com/vmware/govmomi/releases" ;;
    openshift-install) echo "Agent-Based Installer matching your OCP version - console.redhat.com/openshift/install" ;;
    oc)                echo "OpenShift CLI, matching version - console.redhat.com/openshift/install" ;;
    envsubst)          echo "part of the 'gettext' package (dnf/apt install gettext)" ;;
    nmstatectl)        echo "part of the 'nmstate' package (dnf/apt install nmstate) - openshift-install uses it to validate the static network config in agent-config.yaml" ;;
    *)                 echo "no install hint available" ;;
  esac
}

# require_tools <bin>...
# Verifies every named binary is on PATH; aborts listing all the missing ones
# at once (rather than failing on the first) so you can install them in one go.
require_tools() {
  local missing=()
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done

  if (( ${#missing[@]} > 0 )); then
    printf '\n%s%s✗ ERROR:%s missing required tool(s):\n\n' "$C_BOLD" "$C_RED" "$C_RESET" >&2
    for bin in "${missing[@]}"; do
      printf '    %s%-18s%s %s\n' "$C_RED" "$bin" "$C_RESET" "$(tool_hint "$bin")" >&2
    done
    printf '\n  Run %sscripts/check-prereqs.sh%s to re-check.\n\n' "$C_BOLD" "$C_RESET" >&2
    exit 1
  fi
}

# Prints a full pass/fail table of every tool this repo can need. Returns
# non-zero if any are missing. Used by the standalone entry point below.
check_all_prereqs() {
  local all_ok=true bin
  printf '%sChecking required tools for this repo:%s\n\n' "$C_BOLD" "$C_RESET"

  for bin in govc openshift-install oc envsubst nmstatectl; do
    if command -v "$bin" >/dev/null 2>&1; then
      printf '  %s✓%s %-18s %s%s%s\n' "$C_GREEN" "$C_RESET" "$bin" "$C_DIM" "$(command -v "$bin")" "$C_RESET"
    else
      printf '  %s✗%s %-18s %s\n' "$C_RED" "$C_RESET" "$bin" "$(tool_hint "$bin")"
      all_ok=false
    fi
  done

  echo
  if [[ "$all_ok" == "true" ]]; then
    printf '%s%s✓ All required tools are present.%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    return 0
  fi
  printf '%s%s✗ Missing tools listed above. Install them and re-run.%s\n\n' "$C_BOLD" "$C_RED" "$C_RESET"
  return 1
}


# ==========================================
#  vCenter login
# ==========================================

# Authenticates against vCenter as $GOVC_USERNAME and leaves a session token
# cached under $GOVC_HOME for every later govc call in the run.
#
# Password resolution order:
#   1. A still-valid cached session  -> nothing is asked at all
#   2. $VCENTER_PASSWORD (for CI)    -> used non-interactively
#   3. Interactive prompt on the TTY -> typed by the user, never echoed
#
# The password is only ever held in a local variable and passed to the single
# `govc session.login` call as a per-command environment variable, so it is
# never exported into the script's environment nor written to disk.
vcenter_login() {
  [[ -n "${GOVC_URL:-}" ]] || die "GOVC_URL is not set (check config/vcenter-vars.env)"

  # A cached token from an earlier run is usually still valid (vCenter's
  # default idle timeout is ~30 min), so don't ask for a password we
  # don't need.
  if govc session.ls >/dev/null 2>&1; then
    say_ok "Reusing cached vCenter session for ${C_BOLD}${GOVC_USERNAME:-<current>}${C_RESET}"
    return 0
  fi

  [[ -n "${GOVC_USERNAME:-}" ]] || die "GOVC_USERNAME is not set (check config/vcenter-vars.env)"

  local password=""

  # Non-interactive path: let CI export VCENTER_PASSWORD instead of typing.
  if [[ -n "${VCENTER_PASSWORD:-}" ]]; then
    say_info "Using password from \$VCENTER_PASSWORD (non-interactive)"
    password="$VCENTER_PASSWORD"
    GOVC_PASSWORD="$password" govc session.login >/dev/null \
      || die "vCenter login failed for '$GOVC_USERNAME' at '$GOVC_URL'"
  else
    # Interactive path: prompt on the terminal. Read from /dev/tty rather
    # than stdin so this still works if the script's stdin is redirected.
    # Test by actually opening it: /dev/tty can exist but still fail to open
    # when there's no controlling terminal (cron, CI, nohup, containers).
    { : < /dev/tty; } 2>/dev/null || die "$(printf '%s\n       %s' \
      "no valid vCenter session and no terminal available to ask for a password." \
      "Export VCENTER_PASSWORD to log in non-interactively.")"

    local attempt
    for attempt in 1 2 3; do
      printf '  %s?%s Password for %s%s%s at %s%s%s: ' \
        "$C_CYAN" "$C_RESET" \
        "$C_BOLD" "$GOVC_USERNAME" "$C_RESET" \
        "$C_BOLD" "$GOVC_URL" "$C_RESET"

      # -s keeps the password off the screen; the newline it swallows is
      # printed back manually so following output isn't glued to the prompt.
      IFS= read -rs password < /dev/tty
      printf '\n'

      if [[ -z "$password" ]]; then
        say_warn "Empty password, try again ($attempt/3)"
        continue
      fi

      if GOVC_PASSWORD="$password" govc session.login >/dev/null 2>&1; then
        break
      fi

      password=""
      if (( attempt == 3 )); then
        die "vCenter login failed for '$GOVC_USERNAME' at '$GOVC_URL' after 3 attempts"
      fi
      say_warn "Login failed, try again ($attempt/3)"
    done
  fi

  # Scrub every copy of the secret from this shell.
  unset password GOVC_PASSWORD VCENTER_PASSWORD
  say_ok "Authenticated as ${C_BOLD}${GOVC_USERNAME}${C_RESET}; token cached in ${GOVC_HOME:-~/.govc}"
}


# ==========================================
#  Standalone entry point
# ==========================================

# Only runs the report when executed directly - not when sourced by another
# script (which just wants the helper functions defined above).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  check_all_prereqs
fi
