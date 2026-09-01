# Deployment

## Prerequisites

- [Anchor CLI](https://www.anchor-lang.com/docs/installation) v1.1.2
- [Solana CLI](https://docs.solanalabs.com/cli/install) v3.1.14
- Rust 1.89.0

On Windows, use WSL 2. Install the required tools and run the entire deployment
workflow from a WSL terminal.

> **⚠️ Security:** Never commit keypair files to git or share them. The program
> keypair determines the deployed program address; the wallet keypair controls SOL
> and becomes the upgrade authority. Keep secure offline backups of both.

## Quick Start

```bash
# 1. Clone and enter the project
git clone <your-repo-url>
cd vault-program

# 2. Generate a program keypair
solana-keygen new --no-bip39-passphrase -o target/deploy/vault_program-keypair.json

# 3. Configure the Solana CLI wallet that will pay for deployment
solana config set --url devnet
solana airdrop 2
solana balance
# Repeat the airdrop if deployment later reports insufficient funds.

# 4. Build, deploy to devnet, and publish the IDL
./scripts/deploy.sh
```

The script reads the program ID from the keypair and synchronizes it inside a
disposable build copy. The placeholder IDs in `lib.rs` and `Anchor.toml` remain
unchanged. Generated build artifacts are copied to the ignored `target/`
directory after a successful deployment, including the IDL and TypeScript type
used by Anchor clients.

## Deploy Script

```bash
# Defaults: devnet, target/deploy/vault_program-keypair.json
./scripts/deploy.sh

# Deploy to mainnet-beta
CONFIRM_MAINNET=1 ./scripts/deploy.sh mainnet

# With custom keypair
./scripts/deploy.sh devnet path/to/keypair.json

# With env overrides (optional)
RPC_URL=https://api.devnet.solana.com WALLET=~/.config/solana/id.json \
  ./scripts/deploy.sh devnet
```

The script uses one resolved wallet for both the `solana` deployment command
and Anchor IDL publication. A mainnet genesis hash requires
`CONFIRM_MAINNET=1`, even when using a custom RPC URL.

## Multiple Environments

Generate separate keypairs per cluster:

```bash
solana-keygen new --no-bip39-passphrase -o target/deploy/vault_program-devnet-keypair.json
solana-keygen new --no-bip39-passphrase -o target/deploy/vault_program-mainnet-keypair.json
```

Use the second argument to specify which keypair to deploy with:

```bash
./scripts/deploy.sh devnet target/deploy/vault_program-devnet-keypair.json
./scripts/deploy.sh mainnet target/deploy/vault_program-mainnet-keypair.json
```

Each invocation builds with the ID derived from the selected keypair. You do not
need to edit tracked source files or select a Cargo feature when changing
clusters.

## Program Upgrades

The deploy wallet becomes the **upgrade authority** — the same key required by
`init_vault`. Do not remove the upgrade authority while this program relies on
it to authorize vault creation.

```bash
solana program set-upgrade-authority <PROGRAM_ID> \
  --new-upgrade-authority <NEW_PUBKEY>
```

## Closing a Program

To close a deployed program and reclaim the rent:

```bash
solana program close <PROGRAM_ID>
```

Only the upgrade authority can close the program. The rent goes to their wallet.

> ⚠️ This permanently closes the program — all vaults and claim records that depend on it will become unusable.
