#!/bin/sh
# Reproduces ddtrace `--ini=diff` orig_value corruption / SIGSEGV.
#
# - Part 1: data corruption — `php -n -d extension=ddtrace.so --ini=diff` prints
#           garbage in the "default" column of every datadog.* directive.
# - Part 2: SIGSEGV — loading ddtrace + one other extension via php.ini and
#           running `php --ini=diff` segfaults with high probability.
#
# Background: Zend/php_ini.c:display_ini_entries_diff (added in PHP 8.5) prints
# every ini entry's orig_value via php_printf("%s", ...). ddtrace registers all
# datadog.* directives with a shared dangling/uninitialised orig_value pointer,
# so the printf either prints garbage (always) or dereferences an unmapped
# address (when the address happens to land in unmapped memory — depends on
# process layout, hence the second extension).

set -eu

ITERATIONS=${ITERATIONS:-100}

EXT_DIR=$(php -r 'echo ini_get("extension_dir");')
DDTRACE_SO="$EXT_DIR/ddtrace.so"
if [ ! -f "$DDTRACE_SO" ]; then
  echo "ERROR: ddtrace.so not found at $DDTRACE_SO" >&2
  ls -la "$EXT_DIR" >&2 || true
  exit 1
fi

echo "==================================================================="
echo "PHP:        $(php -v | head -1)"
echo "OS:         $(. /etc/os-release && echo "$PRETTY_NAME") ($(uname -m))"
echo "ddtrace.so: $DDTRACE_SO"
echo "==================================================================="
echo

echo "--- Part 1: data corruption (always reproducible) ---"
echo "\$ php -n -d extension=\$DDTRACE_SO --ini=diff | head -10"
PART1_OUT=$(php -n -d "extension=$DDTRACE_SO" --ini=diff 2>/dev/null)
echo "$PART1_OUT" | head -10
echo "..."
echo "(every datadog.* directive shows the same garbage string in the default column;"
echo " run again and you'll see different garbage — ASLR-derived)"
echo

# A correctly-registered INI directive with no override should print
# orig_value as "" (empty). The bug shows non-empty garbage. Detect that
# programmatically: any datadog.* line whose orig column is not "".
CORRUPTED_LINES=$(echo "$PART1_OUT" | grep -E '^datadog\.[^:]+: "[^"]+" -> ' | wc -l | tr -d ' ')
TOTAL_LINES=$(echo "$PART1_OUT" | grep -cE '^datadog\.' || true)
if [ "$CORRUPTED_LINES" -gt 0 ]; then
  echo "PART1_RESULT: data corruption observed ($CORRUPTED_LINES / $TOTAL_LINES datadog.* directives have non-empty orig_value)"
else
  echo "PART1_RESULT: no data corruption observed ($TOTAL_LINES datadog.* directives total)"
fi
echo

echo "--- Part 2: SIGSEGV reproduction (ddtrace + pcov via php.ini) ---"
# Both ddtrace and pcov are loaded via /usr/local/etc/php/conf.d/ — ddtrace
# was wired up by the Datadog installer (98-ddtrace.ini) and pcov by
# docker-php-ext-enable. No further setup needed.

echo "Loaded extensions (via php.ini):"
php -r 'foreach (["ddtrace","pcov"] as $e) printf("  %-10s %s\n", $e, extension_loaded($e) ? "loaded" : "NOT LOADED");'
echo

echo "Running 'php --ini=diff' ${ITERATIONS} times..."
SEGV=0
OK=0
OTHER=0
# `set +e` so a failing/segfaulting `php --ini=diff` doesn't kill the loop.
set +e
for i in $(seq 1 "$ITERATIONS"); do
  php --ini=diff >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0)   OK=$((OK+1)) ;;
    139) SEGV=$((SEGV+1)) ;;
    *)   OTHER=$((OTHER+1)) ;;
  esac
done
set -e

echo
printf "  exit 0   (OK):       %3d / %d\n" "$OK"   "$ITERATIONS"
printf "  exit 139 (SIGSEGV):  %3d / %d\n" "$SEGV" "$ITERATIONS"
printf "  other:               %3d / %d\n" "$OTHER" "$ITERATIONS"
echo

echo "PART2_RESULT: SIGSEGV $SEGV / $ITERATIONS"
echo

# Overall: bug is reproduced if either symptom is present.
if [ "$CORRUPTED_LINES" -gt 0 ] || [ "$SEGV" -gt 0 ]; then
  echo "OVERALL: BUG REPRODUCED"
  exit 0
else
  echo "OVERALL: BUG NOT REPRODUCED"
  exit 1
fi
