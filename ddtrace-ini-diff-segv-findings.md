# ddtrace `--ini=diff` orig_value corruption / SIGSEGV — investigation summary

Investigation notes recording what we've confirmed so far, kept as
working material for assembling a standalone reproduction repo.

## 1. TL;DR

- **Underlying bug**: the `ddtrace` extension registers every `datadog.*`
  INI directive with a "broken `orig_value` pointer". All `datadog.*`
  directives share **the same single dangling/uninitialised pointer**
  as their `orig_value`.
- **How it became visible**: `php --ini=diff`, introduced in PHP 8.5,
  prints each INI directive's `orig_value` via `%s`, so the contents
  of that broken pointer end up in the output (garbage bytes). Before
  PHP 8.5 nothing exercised a code path that read every directive's
  `orig_value`, so the bug stayed dormant.
- **Symptoms**:
  1. **Data corruption (universal)**: `--ini=diff` prints
     `datadog.* : "<garbage>" -> "<actual value>"`. Reproducible from
     a single command line:
     `php -n -d extension=ddtrace.so --ini=diff`.
  2. **SIGSEGV (memory-layout dependent)**: when the broken pointer
     happens to land in unmapped memory, `php_printf` /
     `php_printf_to_smart_string` segfaults. In our environment,
     loading `ddtrace + any one extra .so` via `php.ini` reproduces
     this 100% of the time.
- **Where the fix belongs**: upstream ddtrace
  (https://github.com/DataDog/dd-trace-php). Storing `orig_value` as a
  string literal or in a persistent buffer at INI-registration time
  fixes both symptoms.

## 2. Confirmed environment

- PHP 8.5.5 (colopl/docker-php image, derived from `php:8.5-cli`)
- ddtrace extension: `/opt/datadog-php/extensions/ddtrace-20250925.so`
  (from the official Datadog installer)
- aarch64 (Apple Silicon, OrbStack)
- `php --ini=diff` is a new CLI flag added in PHP 8.5; this code path
  doesn't exist in 8.4 or earlier.

## 3. Evidence of data corruption

Disabling all `php.ini` files with `-n` and loading only ddtrace via
`-d extension=...` is enough to surface garbage `orig_value` for every
`datadog.*` directive:

```sh
$ php -n -d extension=/opt/datadog-php/extensions/ddtrace-20250925.so --ini=diff
Non-default INI settings:
datadog.agent_host: "�K����" -> "localhost"
datadog.amqp_analytics_enabled: "�K����" -> "0"
datadog.amqp_analytics_sample_rate: "�K����" -> "1.0"
datadog.api_key: "�K����" -> ""
datadog.apm_tracing_enabled: "�K����" -> "true"
...
```

Notes:

- The "default" column for every `datadog.*` directive references **the
  same single broken pointer** (the same string is printed every time).
  This strongly suggests the ddtrace INI-registration loop is storing
  the address of one shared temporary buffer / stack region in the
  `orig_value` field of every entry.
- Different processes show different garbage (ASLR-derived). Within a
  single process, the garbage is identical across entries.

## 4. Conditions for the SIGSEGV symptom (measured at n=100)

| config | broken orig_value printed | SIGSEGV rate |
|---|---|---|
| `php -n -d extension=ddtrace.so --ini=diff` | yes | 0/100 |
| `php -n -d extension=pcov -d extension=ddtrace.so --ini=diff` | yes | 0/100 |
| `php -d extension=pcov -d extension=ddtrace.so --ini=diff` (with php.ini) | yes | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff` (ddtrace.ini only) | yes | 0/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff` (grpc.ini + ddtrace.ini) | yes | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff` (xdebug.ini + ddtrace.ini) | yes | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff` (pcov.ini + ddtrace.ini) | yes | 100/100 |
| `PHP_INI_SCAN_DIR=$tmp php --ini=diff` (colopl_bc.ini + ddtrace.ini) | yes | 0/100 |

Takeaways:

- ddtrace alone does not SEGV (the broken `orig_value` happens to land
  on a readable garbage region).
- Either "load one more `.so`" or "read `php.ini`" is enough to shift
  the memory layout so the broken `orig_value` lands in unmapped
  memory — at which point we see 100% SEGV.
- `.so`s that produced 100% SEGV when co-loaded: `grpc`, `xdebug`,
  `pcov`. **`pcov` has the cheapest build** (a few seconds), so it's
  the best fit for an upstream reproduction.
- `colopl_bc` was the only one at 0% (the broken pointer happened to
  stay in a readable region by coincidence).

## 5. gdb backtrace (at SEGV)

Stack when `php --ini=diff` crashes (the build has no debug symbols
so we get `??` for many frames, but PHP function names come through):

```
#0  in libc.so.6                              # likely __strlen / memcpy on the bad pointer
#1  ??                                        # inside the SAPI cli display_ini_entries_diff
#2  php_printf_to_smart_string ()
#3  zend_vspprintf ()
#4  php_printf ()
#5  ??                                        # the SAPI cli diff-printing loop
#6  ??                                        # main
#7  __libc_start_main () from libc.so.6
#8  _start ()
```

The standard pattern: `php_printf("...%s...", entry->orig_value, ...)`
hits an unmapped page through `orig_value` and libc's string
processing crashes.

## 6. Hypothesised location of the upstream bug

The `Zend/zend_ini.c` API is supposed to copy and retain `orig_value`
internally at registration time. So one of the following is presumably
happening on the ddtrace side:

- ddtrace builds `zend_ini_entry` structs by hand and inserts them into
  the hash directly, storing the address of a stack-local temporary
  buffer in `orig_value`.
- Or it stores the address of a heap buffer that is freed immediately
  after registration.
- Or it doesn't initialise `orig_value` at all (so what's left is
  whatever garbage was in the freshly malloc'd memory).

The first step is to grep for places in `dd-trace-php` that build
`orig_value` or `ini_entry` directly.

## 7. Minimal reproduction proposals (for the upstream report)

### 6.1 Single-command-line evidence (data corruption)

```sh
php -n -d extension=/path/to/ddtrace.so --ini=diff
```

→ Produces a stream of `datadog.* : "<garbage>" -> "<value>"`. One
command line + the ddtrace.so on its own.

### 6.2 Reliable SIGSEGV reproduction (evidence of severity)

```sh
# php:8.5-cli + pcov + ddtrace
docker run --rm -v /opt/datadog-php:/opt/datadog-php php:8.5-cli sh -c '
  apt-get update -qq && apt-get install -y --no-install-recommends $PHPIZE_DEPS >/dev/null
  pecl install pcov >/dev/null 2>&1
  docker-php-ext-enable pcov
  echo "extension=/opt/datadog-php/extensions/ddtrace-XXXXXXXX.so" \
    > /usr/local/etc/php/conf.d/zz-ddtrace.ini
  for i in $(seq 1 100); do
    php --ini=diff >/dev/null 2>&1; echo $?
  done | sort | uniq -c
'
```

→ Expect `139` (SEGV) 100 times.

Note: instead of `-v /opt/datadog-php:/opt/datadog-php`, you can run
the official Datadog installer inside the container so no external
mount is needed.

## 8. Open questions (to clean up while assembling the repro repo)

- [ ] Does the stock `php:8.5-cli` + the official Datadog installer +
  pcov combination really produce 100% SEGV? (Or is this dependent on
  the colopl-baked image?)
- [ ] Does it reproduce on amd64 at the same rate?
- [ ] Does the behavior change between PHP 8.5.0 / 8.5.1 / 8.5.5? (We
  observed on 8.5.5.)
- [ ] Does it reproduce on other ddtrace versions (e.g. 1.5, 1.10,
  latest)? Which versions are affected?
- [ ] Where does the broken `orig_value` come from? Try
  `grep -r 'orig_value\|REGISTER_INI_ENTRIES'` over the ddtrace source.

## 9. Operational workarounds for the time being

- Don't call `php --ini=diff`. Pure user-education workaround.
- If you really need to call it, narrow the loaded extensions with
  `-n -d extension=...` and don't include ddtrace.
- `ddtrace.disable=1` does **not** help — the extension is still loaded,
  so its INI registration still runs.
