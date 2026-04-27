# ddtrace `--ini=diff` orig_value corruption / SIGSEGV repro

Minimal, self-contained reproduction of an ini-registration bug in the
[`ddtrace`](https://github.com/DataDog/dd-trace-php) PHP extension, surfaced
by `php --ini=diff` (added in PHP 8.5).

All `datadog.*` ini directives are registered with the **same shared,
dangling/uninitialised `orig_value` pointer**. PHP 8.5's `--ini=diff`
prints every directive's `orig_value` via `php_printf("%s", ...)`, so:

1. **Data corruption (universal)** — every `datadog.*` row prints the
   same garbage string in the "default" column.
2. **SIGSEGV (layout-dependent)** — when the dangling pointer happens to
   land in unmapped memory, the `printf` segfaults. Loading any second
   extension via `php.ini` is enough to push the layout there reliably.

See [`ddtrace-ini-diff-segv-findings.md`](./ddtrace-ini-diff-segv-findings.md)
for the full investigation notes.

## Setup

- Base image: official `php:8.5-cli` (Debian) and `php:8.5-cli-alpine`.
- ddtrace: installed via the official Datadog installer
  (`datadog-setup.php`), which also auto-creates
  `/usr/local/etc/php/conf.d/98-ddtrace.ini`.
- Second extension: **none added** — the stock images already enable
  `sodium` via `conf.d`, which is enough as the second extension loaded
  via `php.ini` to push the layout into the SEGV regime.

Earlier versions of this repo installed `pcov` as an explicit second
extension (per the original findings notes); empirically the
default-shipped `sodium` is sufficient on the layouts we tested.

## Run locally

```sh
# Debian
docker build -f Dockerfile.debian -t ddtrace-segv-repro:debian .
docker run --rm ddtrace-segv-repro:debian

# Alpine
docker build -f Dockerfile.alpine -t ddtrace-segv-repro:alpine .
docker run --rm ddtrace-segv-repro:alpine
```

Override iteration count (default 100):

```sh
docker run --rm -e ITERATIONS=10 ddtrace-segv-repro:debian
```

Pin a specific ddtrace release instead of `latest`:

```sh
docker build -f Dockerfile.debian \
  --build-arg DD_TRACE_RELEASE=1.18.0 \
  -t ddtrace-segv-repro:debian .
```

## Output

The script prints a few machine-readable result lines at the end:

```
PART1_RESULT: data corruption observed (378 / 378 datadog.* directives have non-empty orig_value)
PART2_RESULT: SIGSEGV 100 / 100
OVERALL: BUG REPRODUCED
```

Exit code is `0` when either symptom reproduces, `1` otherwise (e.g. if
the bug is fixed upstream).

## CI

`.github/workflows/repro.yml` runs the full {debian, alpine} ×
{amd64, arm64} matrix on native runners (`ubuntu-latest` for amd64,
`ubuntu-24.04-arm` for arm64). Docker layer cache uses `type=gha`
scoped per `(os, arch)`, so each cell keeps its own cached ddtrace
install layer.

The job doesn't assert on outcomes — it just runs the repro and posts
the full output plus a summary (Part 1 result, SIGSEGV count) to the
job summary, so you can read what each combination actually does.
SIGSEGV is layout-dependent, so a green CI run does not mean the bug
is gone — read the summary.

Trigger manually with custom inputs via the **Run workflow** button.

## Confirmed reproductions

`Part 1` = at least one `datadog.*` directive wrongly appears in
`php -n -d extension=ddtrace.so --ini=diff` (universal symptom — orig
should equal value, so nothing should appear).

See the latest CI run for current numbers across the {debian, alpine}
× {amd64, arm64} matrix. The visible orig_value form differs by layout
(garbage bytes, `(none)`, or `""`), but the row appearing at all is
the bug.
