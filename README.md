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
- Second extension: `pcov` (smallest co-extension; ~5s to build).

Both extensions end up loaded via `conf.d`, which is what the SEGV path
needs.

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

`.github/workflows/repro.yml` runs both Debian and Alpine on
`ubuntu-latest` (amd64). Docker layer cache is wired up via
`type=gha` (scoped per-OS) so the ddtrace + pcov layers don't get
rebuilt every push.

The job fails only if **Part 1 (data corruption)** stops reproducing —
that's the universal, layout-independent symptom. The SIGSEGV count is
reported in the job summary but doesn't gate the build, since whether
amd64 segfaults at the same rate as aarch64 is an open question per
the findings notes.

Trigger manually with custom inputs via the **Run workflow** button.

## Confirmed reproductions

| host arch | os     | data corruption | SIGSEGV (n=100) |
|-----------|--------|-----------------|-----------------|
| aarch64   | debian | yes             | 100/100         |
| aarch64   | alpine | yes             | 100/100         |
| amd64     | debian | tbd via CI      | tbd via CI      |
| amd64     | alpine | tbd via CI      | tbd via CI      |
