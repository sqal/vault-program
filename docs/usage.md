# TypeScript Usage

The on-chain program uses a fixed `[u8; 32]` vault ID. Applications can use an existing 32-byte identifier or deterministically hash a human-readable string. Only `init_vault` receives the ID as instruction data; later instructions receive the vault account explicitly.

## With Anchor

```bash
npm install @coral-xyz/anchor @solana/web3.js
```

```typescript
import { Program, AnchorProvider, Wallet, BN } from "@coral-xyz/anchor";
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

// ── Instructions ─────────────────────────────────────────────

// init_vault — only programData is unresolvable
const vaultId = vaultIdFromString("my-vault-001");
const [vaultPk] = vaultPDA(vaultId);
const [programData] = programDataPDA(program.programId);
await program.methods
  .initVault(vaultId)
  .accounts({ programData })
  .rpc();

// The vault account is explicit after initialization.
await program.methods
  .deposit(new BN(1_000_000_000))
  .accounts({ vault: vaultPk })
  .rpc();

await program.methods
  .closeVault()
  .accounts({ vault: vaultPk })
  .rpc();

const claimantKeypair = Keypair.generate();
const claimant = claimantKeypair.publicKey;
const [claimRecordPk] = PublicKey.findProgramAddressSync(
  [Buffer.from("claim"), vaultPk.toBuffer(), claimant.toBuffer()],
  program.programId,
);
await program.methods
  .setClaimable(new BN(500_000_000))
  .accounts({ vault: vaultPk, claimant })
  .rpc();

await program.methods
  .claim()
  .accounts({ vault: vaultPk, recipient: claimant })
  .rpc();

await program.methods
  .withdraw(new BN(300_000_000))
  .accounts({ vault: vaultPk, destination: wallet.publicKey })
  .rpc();

await program.methods
  .withdrawAll()
  .accounts({ vault: vaultPk, destination: wallet.publicKey })
  .rpc();

await program.methods
  .cleanupVault()
  .accounts({ vault: vaultPk, destination: wallet.publicKey })
  .rpc();

// cleanup_claim_record is vault-independent.
await program.methods
  .cleanupClaimRecord()
  .accounts({ claimRecord: claimRecordPk, signer: claimant })
  .signers([claimantKeypair])
  .rpc();

// ── Fetch state ─────────────────────────────────────────────

const vault = await program.account.vault.fetch(vaultPk);
console.log(vault.authority.toString());
console.log(vault.totalDeposited.toString());

const claim = await program.account.claimRecord.fetch(claimRecordPk);
console.log(
  Number(claim.claimedAt) === 0
    ? "Unclaimed"
    : `Claimed at ${new Date(Number(claim.claimedAt) * 1000)}`,
);

```

## With @solana/kit

> **Note:** `@solana/kit` is the newer successor of `@solana/web3.js` (now in maintenance mode). However, Anchor still depends on `@solana/web3.js` and cannot use `@solana/kit` directly. Presently there is no Anchor-equivalent framework built on `@solana/kit`.

Building instructions manually from the IDL is possible but verbose.

```bash
npm install @solana/kit
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

See the [IDL](../target/idl/vault_program.json) for instruction discriminators and account layouts.
