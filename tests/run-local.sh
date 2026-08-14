#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

cleanup() {
  local status=$?

  if [[ -n "$VALIDATOR_PID" ]]; then
    kill "$VALIDATOR_PID" 2>/dev/null || true
    wait "$VALIDATOR_PID" 2>/dev/null || true
  fi

  case "$(basename "$TEST_TMP")" in
    vault-program-test.*) rm -rf -- "$TEST_TMP" ;;
  esac

  exit "$status"
}
trap cleanup EXIT INT TERM

for command in anchor bun solana solana-keygen solana-test-validator; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command not found: $command" >&2
    exit 1
  fi
done

echo "Vault Program local integration test"

mkdir -p \
  "$TEST_REPO/programs/vault-program/src" \
  "$TEST_REPO/target/deploy" \
  "$BUILD_CACHE/debug" \
  "$BUILD_CACHE/release" \
  "$BUILD_CACHE/sbpf-solana-solana"
ln -s "$BUILD_CACHE/debug" "$TEST_REPO/target/debug"
ln -s "$BUILD_CACHE/release" "$TEST_REPO/target/release"
ln -s "$BUILD_CACHE/sbpf-solana-solana" "$TEST_REPO/target/sbpf-solana-solana"

cp "$ROOT/Anchor.toml" "$TEST_REPO/Anchor.toml"
cp "$ROOT/Cargo.toml" "$TEST_REPO/Cargo.toml"
cp "$ROOT/Cargo.lock" "$TEST_REPO/Cargo.lock"
cp "$ROOT/programs/vault-program/Cargo.toml" "$TEST_REPO/programs/vault-program/Cargo.toml"
cp "$ROOT/programs/vault-program/src/lib.rs" "$TEST_REPO/programs/vault-program/src/lib.rs"

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

solana-test-validator \
  --reset \
  --quiet \
  --ledger "$TEST_TMP/ledger" \
  --rpc-port "$RPC_PORT" \
  --faucet-port "$FAUCET_PORT" \
  >"$VALIDATOR_LOG" 2>&1 &
VALIDATOR_PID=$!

for _ in {1..30}; do
  if solana cluster-version --url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! solana cluster-version --url "$RPC_URL" >/dev/null 2>&1; then
  echo "Error: local validator did not become ready" >&2
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

if ! solana program deploy "$PROGRAM_SO" \
  --program-id "$PROGRAM_KEYPAIR" \
  --keypair "$TEST_WALLET" \
  --url "$RPC_URL" >"$DEPLOY_LOG" 2>&1; then
  echo "Error: temporary program deployment failed" >&2
  tail -100 "$DEPLOY_LOG" >&2
  exit 1
fi

# Give the local validator time to mark the new program executable.
sleep 2
solana program show "$PROGRAM_ID" --url "$RPC_URL" >/dev/null
echo "  ✓ Temporary program deployed"

RPC_URL="$RPC_URL" \
TEST_WALLET_PATH="$TEST_WALLET" \
TEST_IDL_PATH="$IDL_FILE" \
bun "$ROOT/tests/smoke.ts"

printf '\n✓ All tests passed!\n'
