# Quickstart

Generate the default interactive report:

```bash
mix reach
```

Map the current project:

```bash
mix reach.map
mix reach.map --modules
mix reach.map --coupling
mix reach.map --hotspots
```

Inspect a function:

```bash
mix reach.inspect MyApp.Accounts.create_user/1 --context
mix reach.inspect lib/my_app/accounts.ex:42 --impact
mix reach.inspect MyApp.Accounts.create_user/1 --why MyApp.Repo
```

Trace data:

```bash
mix reach.trace --from conn.params --to Repo
mix reach.trace --variable changeset --in MyApp.Accounts.create_user/1
```

Run release checks:

```bash
mix reach.check --arch
mix reach.check --changed --base main
mix reach.check --candidates
```

Inspect OTP risks:

```bash
mix reach.otp
mix reach.otp --concurrency
```
