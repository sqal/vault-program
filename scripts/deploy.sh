#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER="${1:-devnet}"
KEYPAIR="${2:-$ROOT/target/deploy/vault_program-keypair.json}"
BUILD_TMP=""

# Override via env vars (optional)
RPC_URL="${RPC_URL:-}"
WALLET="${WALLET:-}"

cleanup() {
  local status=$?

  if [[ -n "$BUILD_TMP" ]]; then
    case "$(basename "$BUILD_TMP")" in
      vault-program-deploy.*) rm -rf -- "$BUILD_TMP" ;;
    esac
  fi

  exit "$status"
}
trap cleanup EXIT INT TERM

for command in anchor solana solana-keygen; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command not found: $command" >&2
    exit 1
  fi
done

if [ ! -f "$KEYPAIR" ]; then
  echo "Error: keypair not found at $KEYPAIR"
  echo ""
  echo "Generate one:"
  echo "  solana-keygen new --no-bip39-passphrase -o $KEYPAIR"
  echo ""
  echo "The deploy script will apply its program ID in a disposable build copy."
  echo "The placeholders in this repository do not need to be edited."
  exit 1
fi

PROGRAM_ID=$(solana-keygen pubkey "$KEYPAIR")

if [[ -n "$RPC_URL" ]]; then
  RPC_TARGET="$RPC_URL"
else
  case "$CLUSTER" in
    mainnet) RPC_TARGET="mainnet-beta" ;;
    localnet) RPC_TARGET="localhost" ;;
    *) RPC_TARGET="$CLUSTER" ;;
  esac
fi

SOLANA_URL_ARGS=(--url "$RPC_TARGET")
SOLANA_WALLET_ARGS=()
ANCHOR_PROVIDER_ARGS=(--provider.cluster "$RPC_TARGET")
if [[ -n "$WALLET" ]]; then
  SOLANA_WALLET_ARGS=(--keypair "$WALLET")
  ANCHOR_PROVIDER_ARGS+=(--provider.wallet "$WALLET")
fi

echo "Cluster     : $CLUSTER"
echo "Program ID  : $PROGRAM_ID"
echo "Keypair     : $KEYPAIR"
echo "Wallet      : ${WALLET:-<solana config default>}"
echo "RPC         : $RPC_TARGET"
echo ""

echo "Building from a disposable copy..."
BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-program-deploy.XXXXXX")"
BUILD_REPO="$BUILD_TMP/repo"
BUILD_CACHE="$ROOT/target/deploy-build-cache"

mkdir -p \
  "$BUILD_REPO/programs/vault-program/src" \
  "$BUILD_REPO/target/deploy" \
  "$BUILD_CACHE/debug" \
  "$BUILD_CACHE/release" \
  "$BUILD_CACHE/sbpf-solana-solana"
ln -s "$BUILD_CACHE/debug" "$BUILD_REPO/target/debug"
ln -s "$BUILD_CACHE/release" "$BUILD_REPO/target/release"
ln -s "$BUILD_CACHE/sbpf-solana-solana" "$BUILD_REPO/target/sbpf-solana-solana"

cp "$ROOT/Anchor.toml" "$BUILD_REPO/Anchor.toml"
cp "$ROOT/Cargo.toml" "$BUILD_REPO/Cargo.toml"
cp "$ROOT/Cargo.lock" "$BUILD_REPO/Cargo.lock"
cp "$ROOT/programs/vault-program/Cargo.toml" \
  "$BUILD_REPO/programs/vault-program/Cargo.toml"
cp "$ROOT/programs/vault-program/src/lib.rs" \
  "$BUILD_REPO/programs/vault-program/src/lib.rs"
cp "$KEYPAIR" "$BUILD_REPO/target/deploy/vault_program-keypair.json"

(
  cd "$BUILD_REPO"
  anchor keys sync >/dev/null
  anchor build
)

PROGRAM_SO="$BUILD_REPO/target/deploy/vault_program.so"
IDL_FILE="$BUILD_REPO/target/idl/vault_program.json"

echo "Deploying..."
solana program deploy "$PROGRAM_SO" \
  --program-id "$KEYPAIR" \
  "${SOLANA_WALLET_ARGS[@]}" \
  "${SOLANA_URL_ARGS[@]}" \
  --max-sign-attempts 1000 \
  --with-compute-unit-price 200000

echo "Publishing IDL..."
if ! anchor idl init "$PROGRAM_ID" -f "$IDL_FILE" \
  "${ANCHOR_PROVIDER_ARGS[@]}" 2>/dev/null; then
  anchor idl upgrade "$PROGRAM_ID" -f "$IDL_FILE" \
    "${ANCHOR_PROVIDER_ARGS[@]}"
fi

mkdir -p "$ROOT/target/deploy" "$ROOT/target/idl"
cp "$PROGRAM_SO" "$ROOT/target/deploy/vault_program.so"
cp "$IDL_FILE" "$ROOT/target/idl/vault_program.json"

echo ""
echo "Done! $PROGRAM_ID deployed to $CLUSTER"
