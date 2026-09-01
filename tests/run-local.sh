#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/disposable-build.sh
source "$ROOT/scripts/lib/disposable-build.sh"
MODE="${1:-test}"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-program-test.XXXXXX")"
TEST_REPO="$TEST_TMP/repo"
TEST_WALLET="$TEST_TMP/test-wallet.json"
BUILD_LOG="$TEST_TMP/build.log"
DEPLOY_LOG="$TEST_TMP/deploy.log"
VALIDATOR_LOG="$TEST_TMP/validator.log"
VALIDATOR_PID=""
BUILD_CACHE="$ROOT/target/local-test-cache"

RPC_PORT="${VAULT_TEST_RPC_PORT:-18899}"
FAUCET_PORT="${VAULT_TEST_FAUCET_PORT:-19900}"
RPC_URL="http://127.0.0.1:$RPC_PORT"

case "$MODE" in
  test|--typecheck) ;;
  *)
    echo "Usage: $0 [--typecheck]" >&2
    exit 2
    ;;
esac

cleanup() {
  local status=$?

  if [[ -n "$VALIDATOR_PID" ]]; then
    kill "$VALIDATOR_PID" 2>/dev/null || true
    wait "$VALIDATOR_PID" 2>/dev/null || true
  fi

  case "$(basename "$TEST_TMP")" in
    vault-program-test.*)
      if [[ "${VAULT_TEST_KEEP_ARTIFACTS:-}" == "1" ]]; then
        echo "Test artifacts preserved at $TEST_TMP" >&2
      else
        rm -rf -- "$TEST_TMP"
      fi
      ;;
  esac

  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_until() {
  local description="$1"
  local attempts="$2"
  shift 2

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Error: $description did not become ready after $attempts seconds" >&2
  return 1
}

validator_is_ready() {
  solana cluster-version --url "$RPC_URL"
}

program_is_ready() {
  local program_id="$1"
  RPC_URL="$RPC_URL" PROGRAM_ID="$program_id" bun --eval '
    const response = await fetch(process.env.RPC_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "getAccountInfo",
        params: [process.env.PROGRAM_ID, { commitment: "confirmed", encoding: "base64" }],
      }),
    });
    const result = await response.json();
    if (!result.result?.value?.executable) process.exit(1);
  '
}

for command in anchor bun solana solana-keygen solana-test-validator; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command not found: $command" >&2
    exit 1
  fi
done

echo "Vault Program local integration test"

prepare_disposable_workspace "$ROOT" "$TEST_REPO" "$BUILD_CACHE"

solana-keygen new --no-bip39-passphrase --silent --force \
  -o "$TEST_REPO/target/deploy/vault_program-keypair.json" >/dev/null
solana-keygen new --no-bip39-passphrase --silent --force \
  -o "$TEST_WALLET" >/dev/null

if ! (
  cd "$TEST_REPO"
  anchor keys sync >/dev/null
  anchor build
) >"$BUILD_LOG" 2>&1; then
  echo "Error: temporary program build failed" >&2
  tail -200 "$BUILD_LOG" >&2
  exit 1
fi
echo "  ✓ Temporary program built"

mkdir -p "$TEST_REPO/tests"
cp "$ROOT/tests/smoke.ts" "$TEST_REPO/tests/smoke.ts"
cp "$ROOT/tests/tsconfig.json" "$TEST_REPO/tests/tsconfig.json"
mkdir -p "$TEST_REPO/tests/generated" "$ROOT/tests/generated"
cp "$TEST_REPO/target/types/vault_program.ts" \
  "$TEST_REPO/tests/generated/vault_program.ts"
cp "$TEST_REPO/target/types/vault_program.ts" \
  "$ROOT/tests/generated/vault_program.ts"
ln -s "$ROOT/tests/node_modules" "$TEST_REPO/tests/node_modules"
if ! bun x tsc --project "$TEST_REPO/tests/tsconfig.json"; then
  echo "Error: generated Anchor client type-check failed" >&2
  exit 1
fi
echo "  ✓ Generated Anchor client type-check passed"

if [[ "$MODE" == "--typecheck" ]]; then
  exit 0
fi

solana-test-validator \
  --reset \
  --quiet \
  --ledger "$TEST_TMP/ledger" \
  --rpc-port "$RPC_PORT" \
  --faucet-port "$FAUCET_PORT" \
  >"$VALIDATOR_LOG" 2>&1 &
VALIDATOR_PID=$!

if ! wait_until "local validator" 30 validator_is_ready; then
  tail -100 "$VALIDATOR_LOG" >&2
  exit 1
fi
echo "  ✓ Local validator ready"

WALLET_ADDRESS="$(solana-keygen pubkey "$TEST_WALLET")"
solana airdrop 20 "$WALLET_ADDRESS" --url "$RPC_URL" >/dev/null

PROGRAM_SO="$TEST_REPO/target/deploy/vault_program.so"
PROGRAM_KEYPAIR="$TEST_REPO/target/deploy/vault_program-keypair.json"
IDL_FILE="$TEST_REPO/target/idl/vault_program.json"
PROGRAM_ID="$(solana-keygen pubkey "$PROGRAM_KEYPAIR")"
echo "  Program address: $PROGRAM_ID"

if ! solana program deploy "$PROGRAM_SO" \
  --program-id "$PROGRAM_KEYPAIR" \
  --keypair "$TEST_WALLET" \
  --url "$RPC_URL" >"$DEPLOY_LOG" 2>&1; then
  echo "Error: temporary program deployment failed" >&2
  tail -100 "$DEPLOY_LOG" >&2
  exit 1
fi

if ! wait_until "deployed program" 30 program_is_ready "$PROGRAM_ID"; then
  tail -100 "$DEPLOY_LOG" >&2
  tail -100 "$VALIDATOR_LOG" >&2
  exit 1
fi
echo "  ✓ Temporary program deployed"

RPC_URL="$RPC_URL" \
TEST_WALLET_PATH="$TEST_WALLET" \
TEST_IDL_PATH="$IDL_FILE" \
TEST_PROGRAM_ID="$PROGRAM_ID" \
bun "$TEST_REPO/tests/smoke.ts"

printf '\n✓ All tests passed!\n'
