#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/tmp/reach-validation-repos}"
OUT_DIR="${OUT_DIR:-/tmp/reach-review-output}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} -elixir ansi_enabled true"

mkdir -p "$REPO_DIR" "$OUT_DIR"

ensure_repo() {
  local repo="$1"
  local name="$2"
  local path="$REPO_DIR/$name"

  if [ ! -d "$path/.git" ]; then
    echo "==> cloning $repo to $path"
    gh repo clone "$repo" "$path" -- --depth 1 >/dev/null
  fi
}

require_dir() {
  local dir="$1"

  if [ ! -d "$dir" ]; then
    echo "Missing directory: $dir" >&2
    exit 1
  fi
}

run() {
  local name="$1"
  shift

  echo "==> $name"
  "$@" | tee "$OUT_DIR/$name.out"
  echo
}

ensure_repo phoenixframework/phoenix phoenix
ensure_repo elixir-ecto/ecto ecto
ensure_repo oban-bg/oban oban
ensure_repo livebook-dev/livebook livebook
ensure_repo ash-project/ash ash
ensure_repo surface-ui/surface surface

require_dir "$REPO_DIR/phoenix/lib"
require_dir "$REPO_DIR/ecto/lib"
require_dir "$REPO_DIR/oban/lib"
require_dir "$REPO_DIR/livebook/lib"
require_dir "$REPO_DIR/ash/lib"
require_dir "$REPO_DIR/surface/lib"

run phoenix-map \
  mix reach.map "$REPO_DIR/phoenix/lib" --top 20

run ecto-modules \
  mix reach.map "$REPO_DIR/ecto/lib" --modules --top 25

run oban-effects \
  mix reach.map "$REPO_DIR/oban/lib" --effects --top 20

run livebook-data \
  mix reach.map "$REPO_DIR/livebook/lib" --data --top 20

run ash-candidates \
  mix reach.check "$REPO_DIR/ash/lib" --candidates --top 20

run surface-smells \
  mix reach.check "$REPO_DIR/surface/lib" --smells --top 30

run phoenix-otp \
  mix reach.otp "$REPO_DIR/phoenix/lib" --top 20

run oban-otp \
  mix reach.otp "$REPO_DIR/oban/lib" --top 30

run livebook-inspect-context \
  mix reach.inspect "$REPO_DIR/livebook/lib/livebook_web/live/session_live.ex:15" --context --limit 12

html="$OUT_DIR/reach-ecto.html"
run ecto-html \
  mix reach "$REPO_DIR/ecto/lib" --output "$html"

if command -v open >/dev/null 2>&1; then
  open "$html"
fi

echo "Saved review output to $OUT_DIR"
