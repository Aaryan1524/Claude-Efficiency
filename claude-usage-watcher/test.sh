#!/usr/bin/env bash
# Local, side-effect-free test pass for claude_usage_watcher.py.
# Uses a scratch state file (never touches ~/.claude-usage-watcher/) and
# never sends a real Telegram push or schedules a real QStash alarm:
# CLAUDE_NOTIFIER_SECRETS is pointed at a path that doesn't exist, and the
# four secret env vars are explicitly unset, so schedule_alarm/send_telegram
# degrade to their documented no-op-with-a-warning path regardless of
# whether real secrets happen to be present on the machine running this.
#
# Uses /usr/bin/python3 explicitly -- matches what launchd and the hooks
# actually invoke. A plain `python3` on this machine may resolve to a
# python.org install with an uninitialized cert bundle, which fails SSL
# verification on any https call; /usr/bin/python3 uses the system trust
# store and doesn't have that problem. Bit us once already.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SCRIPT_DIR/claude_usage_watcher.py"
PYTHON3=/usr/bin/python3

export CLAUDE_NOTIFIER_STATE=/tmp/watcher_test_state.json
export CLAUDE_NOTIFIER_SECRETS=/tmp/watcher_test_secrets_that_do_not_exist.env
unset CLAUDE_NOTIFIER_TELEGRAM_BOT_TOKEN CLAUDE_NOTIFIER_TELEGRAM_CHAT_ID \
      CLAUDE_NOTIFIER_QSTASH_TOKEN CLAUDE_NOTIFIER_QSTASH_URL
rm -f "$CLAUDE_NOTIFIER_STATE"
rm -f "$(dirname "$CLAUDE_NOTIFIER_STATE")/stop_failure_events.jsonl"

echo "== fresh window starts, ~5h out (expect a 'no cloud alarm scheduled' warning -- that's correct, secrets are deliberately absent here) =="
"$PYTHON3" "$WATCHER" record
"$PYTHON3" "$WATCHER" status

echo
echo "== simulate an elapsed window, confirm check --dry-run previews without consuming it =="
PAST=$("$PYTHON3" -c "from datetime import datetime,timedelta,timezone;print((datetime.now(timezone.utc)-timedelta(minutes=1)).isoformat())")
"$PYTHON3" "$WATCHER" correct five_hour "$PAST"
echo "-- first check (expect: would notify directly, no QStash alarm was scheduled) --"
"$PYTHON3" "$WATCHER" check --dry-run
echo "-- second check (expect: same message AGAIN -- --dry-run never sets notified=True on purpose," \
     "so a later real check still fires for real; idempotency of the real path is only provable" \
     "with a live send, exercised in the README's end-to-end test) --"
"$PYTHON3" "$WATCHER" check --dry-run

echo
echo "== simulate a StopFailure(rate_limit) event with an unknown payload shape =="
echo '{"session_id":"test","hook_event_name":"StopFailure","error_type":"rate_limit"}' \
  | "$PYTHON3" "$WATCHER" hit-limit
echo "-- status (expect: confirmed blocked at) --"
"$PYTHON3" "$WATCHER" status
echo "-- logged raw payload --"
cat "$(dirname "$CLAUDE_NOTIFIER_STATE")/stop_failure_events.jsonl"

rm -f "$CLAUDE_NOTIFIER_STATE"
rm -f "$(dirname "$CLAUDE_NOTIFIER_STATE")/stop_failure_events.jsonl"

echo
echo "All scenarios ran. Review the output above against README.md's expectations."
