# Recipes

## Review a risky change

```bash
mix reach.check --changed --base main
mix reach.inspect MyApp.Target.function/2 --impact
mix reach.inspect MyApp.Target.function/2 --context
```

Use JSON in CI:

```bash
mix reach.check --changed --base main --format json
```

## Find refactoring candidates

```bash
mix reach.check --candidates
mix reach.inspect MyApp.Target.function/2 --candidates
```

Candidates are advisory. Use the evidence fields to prove behavior preservation before editing.

## Trace tainted input

```bash
mix reach.trace --from conn.params --to Repo
mix reach.trace --from conn.params --to System.cmd --all
```

## Inspect OTP coupling

```bash
mix reach.otp
mix reach.otp --concurrency
mix reach.inspect MyApp.Worker.handle_call/3 --context
```
