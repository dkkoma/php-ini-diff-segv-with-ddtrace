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
- Second extension: **pcov** (PECL, ~5–10s build). The lightest of the
  three extensions the upstream findings notes confirmed as reliably
  triggering the SEGV on aarch64 (the others being grpc and xdebug).
  We also tried `apcu` (lighter and more production-common) but it
  did not push amd64 layouts into the SEGV regime in CI, so we settled
  on pcov for repro reliability over production realism.

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

The script prints two machine-readable result lines at the end:

```
PART1_RESULT: bug observed (378 datadog.* directives wrongly appear in --ini=diff; orig_value sample: "@w�r��")
PART2_RESULT: SIGSEGV 100 / 100
```

The script always exits 0 — it doesn't assert, it just reports. Same
for the CI workflow (which posts these lines plus the full output to
the job summary).

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

Latest CI run (`pcov` + ddtrace, n=100):

| os × arch        | Part 1 | SIGSEGV     |
|------------------|--------|-------------|
| debian / arm64   | yes    | **100/100** |
| alpine / arm64   | yes    | **100/100** |
| debian / amd64   | yes    | ~40/100 (flaky, varies run to run) |
| alpine / amd64   | yes    | 0/100       |

Part 1 reproduces on **every** combination. SIGSEGV is layout-dependent:
arm64 always lands on unmapped memory and crashes, debian-amd64 is in a
flaky middle regime (we've observed runs at 0/100, 39/100, 48/100), and
alpine-amd64 (musl) tends to settle on a readable layout where the
`%s` printf walks the garbage and exits cleanly.

The visible `orig_value` form also differs by layout — garbage bytes
on arm64-glibc, `(none)` (NULL pointer) on amd64-glibc when the
uninitialised slot happens to be NULL, etc. — but the directive
appearing in `--ini=diff` at all is the bug. See the latest CI run's
job summary for current numbers and full output.
