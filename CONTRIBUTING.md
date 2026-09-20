# Contributing

This plugin must remain a thin consumer of `appblock list --json`. Do not read
appblock state files, inspect shims, or duplicate blocking decisions in QML or
JavaScript. Actions should invoke the public CLI and then refresh authoritative
state.

Before submitting a change:

```sh
node tests/test_model.js
omarchy plugin validate .
```

Keep `Model.js` free of QML-only constructs so its parsing and formatting logic
remains testable with Node. Update `CHANGELOG.md` and the compatibility table in
`README.md` for user-visible changes or a new supported JSON schema.

For live development, plugin file changes normally rescan automatically. If an
already-instantiated bar widget does not pick up a structural QML change, run:

```sh
omarchy restart shell
```
