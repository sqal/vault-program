#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/disposable-build.sh
source "$ROOT/scripts/lib/disposable-build.sh"

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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

GENESIS_HASH="$(solana genesis-hash --url "$RPC_TARGET")"
MAINNET_GENESIS_HASH="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"
if [[ "$GENESIS_HASH" == "$MAINNET_GENESIS_HASH" && "${CONFIRM_MAINNET:-}" != "1" ]]; then
  echo "Error: refusing mainnet deployment without CONFIRM_MAINNET=1" >&2
  echo "Re-run only after review: CONFIRM_MAINNET=1 $0 $CLUSTER $KEYPAIR" >&2
  exit 1
fi

if [[ -z "$WALLET" ]]; then
  WALLET="$(solana config get | sed -n 's/^Keypair Path: //p')"
fi
if [[ -z "$WALLET" || ! -f "$WALLET" ]]; then
  echo "Error: deployment wallet keypair not found: ${WALLET:-<not configured>}" >&2
  echo "Set WALLET=/path/to/wallet.json or configure Solana CLI." >&2
  exit 1
fi

SOLANA_URL_ARGS=(--url "$RPC_TARGET")
SOLANA_WALLET_ARGS=(--keypair "$WALLET")
ANCHOR_PROVIDER_ARGS=(--provider.cluster "$RPC_TARGET" --provider.wallet "$WALLET")

echo "Cluster     : $CLUSTER"
echo "Program ID  : $PROGRAM_ID"
echo "Keypair     : $KEYPAIR"
echo "Wallet      : $WALLET"
echo "RPC         : $RPC_TARGET"
echo "Genesis hash: $GENESIS_HASH"
echo ""

echo "Building from a disposable copy..."
BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-program-deploy.XXXXXX")"
BUILD_REPO="$BUILD_TMP/repo"
BUILD_CACHE="$ROOT/target/deploy-build-cache"

prepare_disposable_workspace "$ROOT" "$BUILD_REPO" "$BUILD_CACHE"
cp "$KEYPAIR" "$BUILD_REPO/target/deploy/vault_program-keypair.json"

(
  cd "$BUILD_REPO"
  anchor keys sync >/dev/null
  anchor build
)

PROGRAM_SO="$BUILD_REPO/target/deploy/vault_program.so"
IDL_FILE="$BUILD_REPO/target/idl/vault_program.json"
TYPE_FILE="$BUILD_REPO/target/types/vault_program.ts"

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

mkdir -p "$ROOT/target/deploy" "$ROOT/target/idl" "$ROOT/target/types"
cp "$PROGRAM_SO" "$ROOT/target/deploy/vault_program.so"
cp "$IDL_FILE" "$ROOT/target/idl/vault_program.json"
cp "$TYPE_FILE" "$ROOT/target/types/vault_program.ts"

echo ""
echo "Done! $PROGRAM_ID deployed to $CLUSTER"
