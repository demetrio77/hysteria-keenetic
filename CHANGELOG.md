# Changelog

## [Unreleased]

### Fixed
- **Router OOM from dnsmasq debug logging on tmpfs.** On Keenetic, `/tmp` is a
  RAM-backed tmpfs (~244 MB). A leftover debug edit in `dnsmasq.conf`
  (`log-queries` + `log-facility=/tmp/dnsmasq-debug.log`) made dnsmasq write every
  DNS query to RAM with no rotation. Over weeks the log grew until it filled tmpfs
  and triggered an out-of-memory condition that took the router down.
  - `manage.sh` now strips any `log-queries` / `log-facility=` lines from
    `dnsmasq.conf` (and removes a stale `/tmp/dnsmasq-debug.log`) before every
    start. The service writes all process output to `/dev/null` by design, so query
    logging is never shipped.

- **Broken install / self-update URLs (wrong GitHub account).** Both READMEs'
  install one-liner and `manage.sh` self-update pointed at
  `github.com/dnikonov/...` (404 — wrong account), so a fresh `curl … main.tar.gz`
  install failed outright and no user could pull script updates. Corrected to
  `github.com/DenisNikonov/...` in `README.md`, `README.ru.md`, and `manage.sh`.
  This is what lets the OOM fix above actually reach installed routers.

### Added
- `manage.sh status` now reports `/tmp` (RAM tmpfs) usage and warns at ≥80 %, so a
  filling tmpfs is visible before it causes an OOM.
