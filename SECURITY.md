# Security

Ata records people's conversations, so security reports are taken seriously.

## Reporting a vulnerability

**Please don't open a public issue.** Use GitHub's
[private vulnerability reporting](https://github.com/mcpeixoto/Ata/security/advisories/new)
instead. You'll get an answer within a few days, and credit in the release notes if you'd like it.

Things that are especially interesting:

- any way for the local engine to send audio or text off the Mac;
- any way to get the updater to install something that isn't a notarized build from this project;
- leaks of the OpenAI API key out of the keychain;
- recordings ending up anywhere other than the meetings folder.

## Supported versions

Only the latest release gets fixes. Ata updates itself, so that's the version almost everyone runs.

## How updates are verified

Before an update is installed, Ata checks that the download passes
`codesign --verify --deep --strict`, that Gatekeeper accepts it as notarized
(`spctl -a -t install`), and that its Team ID matches the running app's. Any failure leaves the
installed app untouched. See [`Updater.swift`](Sources/Ata/Updater.swift).
