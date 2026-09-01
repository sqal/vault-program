# TypeScript Usage

The on-chain program uses a fixed `[u8; 32]` vault ID. Applications can use an existing 32-byte identifier or deterministically hash a human-readable string. Vault-creation instructions receive the ID as instruction data; later instructions receive the vault account explicitly.

> [!IMPORTANT]
> Claims are authority-controlled. `set_claimable` records an intended payout
> but does not reserve SOL, and `claim` requires the vault authority's signature.
> A claimant cannot redeem a claim record independently.

## With Anchor

The deployment script generates the local IDL and TypeScript type imported by
this example at `target/idl/vault_program.json` and
`target/types/vault_program.ts`. Both paths are build artifacts and are
intentionally ignored by Git.

```bash
bun add @anchor-lang/core@1.1.2 @solana/web3.js
```

```typescript
import { Program, AnchorProvider, Wallet, BN } from "@anchor-lang/core";
import { Connection, PublicKey, Keypair } from "@solana/web3.js";
import { createHash } from "node:crypto";
import idl from "../target/idl/vault_program.json" with { type: "json" };
import type { VaultProgram } from "../target/types/vault_program";

const connection = new Connection("https://api.devnet.solana.com");
const wallet = new Wallet(Keypair.fromSecretKey(...));
const provider = new AnchorProvider(connection, wallet, {});
const program = new Program<VaultProgram>(idl, provider);

function vaultIdFromString(value: string): number[] {
  return [...createHash("sha256").update(value, "utf8").digest()];
}

function vaultPDA(vaultId: number[]) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("vault"), Buffer.from(vaultId)],
    program.programId,
  );
}

function programDataPDA(programId: PublicKey) {
  return PublicKey.findProgramAddressSync(
    [programId.toBuffer()],
    new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111"),
  );
}

function vaultConfigPDA() {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("vault_config")],
    program.programId,
  );
}

// ── Instructions ─────────────────────────────────────────────

// One-time setup by the upgrade authority. `vaultCreator` is the daily backend
// signer permitted to create vaults.
const vaultCreator = wallet.publicKey;
const [vaultConfig] = vaultConfigPDA();
const [programData] = programDataPDA(program.programId);
await program.methods
  .initializeVaultConfig(vaultCreator)
  .accountsPartial({
    vaultConfig,
    authority: wallet.publicKey,
    program: program.programId,
    programData,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

// Vault creation: creator and operational authority may differ.
const vaultId = vaultIdFromString("my-vault-001");
const [vaultPk] = vaultPDA(vaultId);
await program.methods
  .initVault(vaultId, wallet.publicKey)
  .accountsPartial({
    vault: vaultPk,
    vaultConfig,
    vaultCreator,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

// The vault account is explicit after initialization.
await program.methods
  .deposit(new BN(1_000_000_000))
  .accountsPartial({ vault: vaultPk })
  .rpc();

await program.methods
  .closeVault()
  .accountsPartial({ vault: vaultPk })
  .rpc();

const claimantKeypair = Keypair.generate();
const claimant = claimantKeypair.publicKey;
const [claimRecordPk] = PublicKey.findProgramAddressSync(
  [Buffer.from("claim"), vaultPk.toBuffer(), claimant.toBuffer()],
  program.programId,
);
await program.methods
  .setClaimable(new BN(500_000_000))
  .accountsPartial({ vault: vaultPk, claimant })
  .rpc();

await program.methods
  .claim()
  .accountsPartial({ vault: vaultPk, recipient: claimant })
  .rpc();

// ── Fetch state before cleanup closes the accounts ─────────

const vault = await program.account.vault.fetch(vaultPk);
console.log(vault.authority.toString());
console.log(vault.totalDeposited.toString());

const claim = await program.account.claimRecord.fetch(claimRecordPk);
console.log(
  Number(claim.claimedAt) === 0
    ? "Unclaimed"
    : `Claimed at ${new Date(Number(claim.claimedAt) * 1000)}`,
);

await program.methods
  .withdraw(new BN(300_000_000))
  .accountsPartial({ vault: vaultPk, destination: wallet.publicKey })
  .rpc();

await program.methods
  .withdrawAll()
  .accountsPartial({ vault: vaultPk, destination: wallet.publicKey })
  .rpc();

await program.methods
  .cleanupVault()
  .accountsPartial({ vault: vaultPk, destination: wallet.publicKey })
  .rpc();

// cleanup_claim_record is vault-independent.
await program.methods
  .cleanupClaimRecord()
  .accountsPartial({ claimRecord: claimRecordPk, signer: claimant })
  .signers([claimantKeypair])
  .rpc();

```

## With @solana/kit

> **Note:** `@solana/kit` is the newer successor of `@solana/web3.js` (now in maintenance mode). However, Anchor still depends on `@solana/web3.js` and cannot use `@solana/kit` directly. Presently there is no Anchor-equivalent framework built on `@solana/kit`.

Building instructions manually from the IDL is possible but verbose.

```bash
bun add @solana/kit
```

### PDA Derivation

```typescript
import { address, getProgramDerivedAddress, getAddressEncoder } from "@solana/kit";

const PROGRAM_ID = address("YOUR_DEPLOYED_PROGRAM_ID");

async function vaultIdFromString(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
}

async function vaultPDA(vaultId: Uint8Array) {
  return getProgramDerivedAddress({
    programAddress: PROGRAM_ID,
    seeds: [new TextEncoder().encode("vault"), vaultId],
  });
}

async function claimRecordPDA(vault: string, claimant: string) {
  const encoder = getAddressEncoder();
  return getProgramDerivedAddress({
    programAddress: PROGRAM_ID,
    seeds: [
      new TextEncoder().encode("claim"),
      encoder.encode(address(vault)),
      encoder.encode(address(claimant)),
    ],
  });
}
```

After building or deploying, inspect `target/idl/vault_program.json` locally for
instruction discriminators and account layouts.
