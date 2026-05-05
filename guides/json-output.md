# JSON Output

All canonical commands support `--format json` for automation.

```bash
mix reach.map --format json
mix reach.inspect MyApp.Accounts.create_user/1 --context --format json
mix reach.trace --from conn.params --to Repo --format json
mix reach.check --arch --format json
mix reach.otp --format json
```

JSON output is pipe-safe and should not include progress text. Tests decode complete captured output to prevent regressions.

Prefer JSON for agents and CI. Human text output is intentionally summarized, colorized, and may include truncation hints.
