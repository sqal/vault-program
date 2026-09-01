# Vault Program

A PDA-based SOL vault system on Solana. Manage the full lifecycle: create vaults, deposit SOL, assign claim amounts, process claims, withdraw leftovers, and clean up accounts.

Built with [Anchor](https://www.anchor-lang.com/) framework.

> [!WARNING]
> This software has not undergone a professional security audit. Use it at your
> own risk. See the [security policy](SECURITY.md) for vulnerability reporting.

## Features

- Upgrade-authority-controlled vault creation
- PDA-based vault and claim-record accounts
- SOL deposits, authority-managed payouts, and withdrawals
- Explicit open and closed lifecycle states
- Rent recovery through vault and claim-record cleanup
- Anchor client example and `@solana/kit` PDA helpers

## Getting Started

### Requirements

- Anchor CLI 1.1.2
- Solana CLI 3.1.14
- Rust 1.89.0 and Cargo
- Bun (for the integration test)

Windows is supported through WSL 2. Install the requirements and run all build,
test, and deployment commands from a WSL terminal.

### Documentation

- [Deployment guide](docs/deploy.md)
- [TypeScript usage](docs/usage.md)

### Testing

The integration test runs against a disposable local validator. It generates a
temporary program ID and wallets, leaving the placeholders in this repository
unchanged.

```bash
cd tests
bun install
bun run test
```

The test requires Anchor CLI, Solana CLI, `solana-test-validator`, and Bun.
Compiled dependencies are cached under the ignored `target/local-test-cache/`
directory; temporary IDs, keypairs, and validator data are still deleted after
every run. To retain a failed run's build and validator logs for diagnosis, run
`VAULT_TEST_KEEP_ARTIFACTS=1 bun run test`.

## How It Works

### Accounts

**Vault** — Holds deposited SOL for a single vault instance.

| Field              | Type         | Description                       |
| ------------------ | ------------ | --------------------------------- |
| `authority`        | `Pubkey`     | Wallet that controls the vault    |
| `vault_id`         | `[u8; 32]`   | Unique fixed-size vault identifier |
| `status`           | `VaultStatus`| Current lifecycle state           |
| `total_deposited`  | `u64`        | Cumulative lamports deposited     |
| `total_claimed`    | `u64`        | Cumulative lamports claimed       |
| `total_withdrawn`  | `u64`        | Withdrawals counted against tracked deposits |
| `bump`             | `u8`         | PDA bump seed                     |

**Space:** 98 bytes (8 + 32 + 32 + 1 + 8 + 8 + 8 + 1)

**ClaimRecord** — Tracks a payout that the vault authority may process for a
claimant. It does not reserve or escrow SOL.

| Field         | Type      | Description                          |
| ------------- | --------- | ------------------------------------ |
| `vault`       | `Pubkey`  | Associated vault address             |
| `authority`   | `Pubkey`  | Vault authority at time of creation  |
| `claimant`    | `Pubkey`  | Wallet that gets the payout         |
| `amount`      | `u64`     | Authority-managed payout (lamports)  |
| `claimed_at`  | `i64`     | Unix timestamp of claim (0 if unclaimed) |
| `bump`        | `u8`      | PDA bump seed                        |

**Space:** 121 bytes (8 + 32 + 32 + 32 + 8 + 8 + 1)

### PDA Seeds

| Account       | Seeds                                        |
| ------------- | -------------------------------------------- |
| `Vault`       | `["vault", vault_id]`                        |
| `ClaimRecord` | `["claim", vault_pubkey, claimant_pubkey]`   |

### Vault Lifecycle

```
Open ──deposit──► Open ──close_vault──► Closed
                                           │
                              set_claimable / claim
                              withdraw / withdraw_all
                                           │
                                      cleanup_vault
```

### VaultStatus

| Variant  | Description                                               |
| -------- | --------------------------------------------------------- |
| `Open`   | Vault is active — deposits and close are allowed          |
| `Closed` | Locked — claims, withdrawals, and cleanup are now enabled |

## Instructions

### `init_vault(vault_id: [u8; 32])`

Creates a new vault PDA. Only the program's **upgrade authority** can call this — only the deployer can create vaults.

- **Signer:** `authority` (must be program upgrade authority)
- **Accounts:** vault (init), authority, program, program_data, system_program
- **Validations:** `vault_id` cannot be all zeroes; authority must match `program_data.upgrade_authority_address`
- **Status after:** `Open`

### `deposit(amount: u64)`

Transfers SOL from the authority into the vault via CPI to the system program.

- **Signer:** `authority` (vault authority)
- **Accounts:** vault (mut), authority (mut), system_program
- **Validations:** `amount > 0`; vault must be `Open`

### `close_vault()`

Locks the vault, preventing further deposits. Enables claims, withdrawals, and cleanup.

- **Signer:** `authority` (vault authority)
- **Accounts:** vault (mut), authority
- **Validations:** vault status must be `Open`
- **Status after:** `Closed`

### `set_claimable(amount: u64)`

Creates a `ClaimRecord` PDA for a claimant, recording an intended payout. No SOL
is transferred or reserved. The authority can still withdraw funds before the
payout is processed, so a claim record is not a funding guarantee.

- **Signer:** `authority` (vault authority)
- **Accounts:** vault (mut), claimant (unchecked), claim_record (init), authority (mut), system_program
- **Validations:** `amount > 0`; vault must be `Closed`

### `claim()`

Pays out a claimant. The authority—not the claimant—must sign, and SOL transfers
directly from the vault to the recipient. Claimants cannot redeem records
independently.

- **Signer:** `authority` (vault authority)
- **Accounts:** vault (mut), claim_record (mut), authority, recipient (mut)
- **Validations:** vault `Closed`; claim_record matches vault + recipient; not already claimed; sufficient funds

### `withdraw(amount: u64)`

Authority withdraws a specific amount of SOL from the vault.

- **Signer:** `authority` (vault authority)
- **Accounts:** vault (mut), authority, destination (mut)
- **Validations:** `amount > 0`; vault `Closed`; amount ≤ available lamports (above rent-exempt minimum)

### `withdraw_all()`

Authority withdraws all available SOL (above rent-exempt minimum) from the vault.

- **Signer:** `authority` (vault authority)
- **Accounts:** vault (mut), authority, destination (mut)
- **Validations:** vault `Closed`; available > 0

### `cleanup_vault()`

Closes the vault account and gets rent back. The tracked deposited balance must
be settled first (`total_deposited == total_claimed + total_withdrawn`). Claim
records do not reserve funds, so unclaimed records do not block vault cleanup.
Any unsolicited SOL dust is drained before closing.

- **Signer:** `authority` (vault authority)
- **Accounts:** vault (mut, close → destination), authority, destination (mut)
- **Validations:** vault `Closed`; accounting needs to balance

### `cleanup_claim_record()`

Closes a claim record and gets rent back. Two ways:
- **Claimed records:** The **claimant** signs to get their rent back
- **Unclaimed records:** The **authority** signs to clean up abandoned records

Vault-independent — works even after the vault is closed.

- **Signer:** `signer` (claimant or authority)
- **Accounts:** claim_record (mut, close → signer), signer (mut)

## Error Codes

| Code                      | Message                                                    |
| ------------------------- | ---------------------------------------------------------- |
| `InvalidVaultId`          | Invalid vault ID                                           |
| `InvalidAmount`           | Invalid amount                                             |
| `InvalidVaultStatus`      | Vault is not in the correct status for this operation      |
| `InsufficientFunds`       | Insufficient funds in vault                                |
| `Overflow`                | Arithmetic overflow                                        |
| `AlreadyClaimed`          | Payout already claimed                                     |
| `InvalidClaimRecord`      | Claim record does not match expected claimant              |
| `NothingToClaim`          | Nothing to claim                                           |
| `NothingToWithdraw`       | Nothing to withdraw                                        |
| `Unauthorized`            | Unauthorized                                               |
| `VaultAccountingMismatch` | Vault accounting mismatch                                  |

## Security

Please report vulnerabilities privately by following the
[security policy](SECURITY.md).

## License

Licensed under the [MIT License](LICENSE).
