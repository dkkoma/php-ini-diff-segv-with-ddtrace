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

# With `-n` (no INI files) and only ddtrace loaded, NO datadog.* directive
# should appear in --ini=diff: each one's orig_value must equal its current
# value (both = the registration-time default). Every datadog.* line that
# DOES appear is the bug — orig_value is wrong (NULL on amd64-musl, garbage
# elsewhere). The visible orig_value form ("(none)", "", or garbage bytes)
# depends on memory layout, but the presence of the row is universal.
CORRUPTED_LINES=$(echo "$PART1_OUT" | grep -cE '^datadog\.' || true)
SAMPLE_ORIG=$(echo "$PART1_OUT" | grep -E '^datadog\.' | head -1 | sed -E 's/^datadog\.[^:]+: (.*) -> .*/\1/')
if [ "$CORRUPTED_LINES" -gt 0 ]; then
  echo "PART1_RESULT: bug observed ($CORRUPTED_LINES datadog.* directives wrongly appear in --ini=diff; orig_value sample: $SAMPLE_ORIG)"
else
  echo "PART1_RESULT: no bug observed (no datadog.* directives in --ini=diff — possibly fixed upstream)"
fi
echo

echo "--- Part 2: SIGSEGV reproduction (ddtrace + sodium via php.ini) ---"
# ddtrace is loaded via /usr/local/etc/php/conf.d/98-ddtrace.ini (created
# by the Datadog installer). The stock php:8.5-cli image also enables
# sodium via conf.d, which gives us the "second extension loaded via
# php.ini" the SEGV needs. No extra setup.

echo "Files in /usr/local/etc/php/conf.d/:"
ls /usr/local/etc/php/conf.d/ | sed 's/^/  /'
echo
echo "Loaded modules (subset):"
php -r 'foreach (["ddtrace","sodium"] as $e) printf("  %-10s %s\n", $e, extension_loaded($e) ? "loaded" : "NOT LOADED");'
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
exit 0
