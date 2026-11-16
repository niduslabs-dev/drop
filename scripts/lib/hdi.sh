# Shared hdiutil helpers for the fixture scripts. Source it after `set -euo pipefail`:
#   . "$(dirname "$0")/lib/hdi.sh"
#
# hdiutil's `-quiet` hides its errors too, so a failed fixture build used to exit with
# nothing to read. These wrappers stay silent on success and print the command and all of
# hdiutil's output when it fails; callers never pass `-quiet` or redirect it themselves.
#
#   hdi <args>          run hdiutil; no output unless it fails
#   hdi_out <args>      the same, with stdout passed through (for `-plist`)
#   hdi_create <args>   `hdi create -ov <args>`, retried
#   hdi_attach <args>   `hdi_out attach <args>`, retried
#
# Creating and attaching are retried because both fail now and then with "Resource busy"
# on hosted CI runners. A password for `-stdinpass` goes in HDI_STDIN (each try needs it
# again); without it hdiutil reads nothing from stdin.

HDI_TRIES=3
HDI_RETRY_SLEEP=2

set -E
trap 'echo "$0: line $LINENO: \`$BASH_COMMAND\` failed" >&2' ERR

# _hdi <keep-stdout: 0|1> <tries> <hdiutil args>
_hdi() {
    local keep_stdout="$1" tries="$2"
    shift 2
    local log try=1 status
    log="$(mktemp "${TMPDIR:-/tmp}/hdi.XXXXXX")"
    while :; do
        status=0
        if [ "$keep_stdout" = 1 ]; then
            printf '%s' "${HDI_STDIN-}" | hdiutil "$@" 2>"$log" || status=$?
        else
            printf '%s' "${HDI_STDIN-}" | hdiutil "$@" >"$log" 2>&1 || status=$?
        fi
        [ "$status" -eq 0 ] && break
        {
            echo "hdiutil $* failed (exit $status, try $try of $tries):"
            sed 's/^/    /' "$log"
        } >&2
        [ "$try" -ge "$tries" ] && break
        try=$((try + 1))
        sleep "$HDI_RETRY_SLEEP"
    done
    rm -f "$log"
    return "$status"
}

hdi() { _hdi 0 1 "$@"; }
hdi_out() { _hdi 1 1 "$@"; }
hdi_create() { _hdi 0 "$HDI_TRIES" create -ov "$@"; }
hdi_attach() { _hdi 1 "$HDI_TRIES" attach "$@"; }
