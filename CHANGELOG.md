# Changelog

All notable changes are documented here. The LaunchBrake plugin versions
independently from the `appblock` CLI.

## 0.2.1

- Kept the bar widget visible with a `0` count by default so a fresh
  marketplace installation does not appear to have failed.
- Preserved `showWhenNone` as an opt-out setting for users who prefer the
  widget hidden while nothing is blocked.

## 0.2.0

- Adopted the LaunchBrake public project name and permanent namespaced plugin
  ID while preserving `appblock` command compatibility.
- Updated marketplace display metadata and documented safe plugin removal.

## 0.1.1

- Added a 10-second query timeout that clears stale state and reports a visible
  error when `appblock list --json` hangs.
- Documented compatibility with appblock JSON schema 1.

## 0.1.0

- Initial Omarchy bar widget.
- Added live blocked counts, enforcement labels, deadline countdowns, scheduled
  unblock controls, explicit refresh, and CLI launch support.
