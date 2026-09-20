# Changelog

All notable changes are documented here. The LaunchBrake plugin versions
independently from the `appblock` CLI.

## Unreleased

- Adopted the LaunchBrake public project name while preserving the existing
  plugin ID and `appblock` command compatibility.

## 0.1.1

- Added a 10-second query timeout that clears stale state and reports a visible
  error when `appblock list --json` hangs.
- Documented compatibility with appblock JSON schema 1.

## 0.1.0

- Initial Omarchy bar widget.
- Added live blocked counts, enforcement labels, deadline countdowns, scheduled
  unblock controls, explicit refresh, and CLI launch support.
