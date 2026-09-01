import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { AnchorProvider, BN, Program, Wallet } from "@anchor-lang/core";
import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
} from "@solana/web3.js";
import type { VaultProgram } from "./generated/vault_program";

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function vaultId(value: string): number[] {
  return [...createHash("sha256").update(value, "utf8").digest()];
}

function errorDetails(error: unknown): string {
  const anchorError = error as {
    error?: { errorCode?: { code?: string } };
    errorCode?: { code?: string };
    logs?: string[];
    message?: string;
  };
  return [
    anchorError.error?.errorCode?.code,
    anchorError.errorCode?.code,
    anchorError.message,
    ...(anchorError.logs ?? []),
  ]
    .filter(Boolean)
    .join("\n");
}

async function expectAnchorError(promise: Promise<unknown>, expectedCode: string) {
  try {
    await promise;
  } catch (error) {
    assert.match(errorDetails(error), new RegExp(`\\b${expectedCode}\\b`));
    return;
  }

  assert.fail(`Expected Anchor error ${expectedCode}`);
}

async function waitForProgramExecution(
  request: () => Promise<unknown>,
  expectedCode: string,
) {
  for (let attempt = 1; attempt <= 30; attempt++) {
    try {
      await request();
    } catch (error) {
      const details = errorDetails(error);
      if (new RegExp(`\\b${expectedCode}\\b`).test(details)) return;
      if (!details.includes("Unsupported program id")) throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  assert.fail("Program did not become execution-ready within 7.5 seconds");
}

const rpcUrl = requiredEnv("RPC_URL");
const walletPath = requiredEnv("TEST_WALLET_PATH");
const idlPath = requiredEnv("TEST_IDL_PATH");
const programId = requiredEnv("TEST_PROGRAM_ID");
const wallet = new Wallet(
  Keypair.fromSecretKey(
    new Uint8Array(JSON.parse(readFileSync(walletPath, "utf8"))),
  ),
);
const connection = new Connection(rpcUrl, "confirmed");
const provider = new AnchorProvider(connection, wallet, {
  commitment: "confirmed",
  preflightCommitment: "confirmed",
});
const idl = {
  ...JSON.parse(readFileSync(idlPath, "utf8")),
  address: programId,
} as VaultProgram;
const program = new Program<VaultProgram>(idl, provider);
const programData = PublicKey.findProgramAddressSync(
  [program.programId.toBuffer()],
  new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111"),
)[0];
const vaultConfig = PublicKey.findProgramAddressSync(
  [Buffer.from("vault_config")],
  program.programId,
)[0];

async function initVault(
  id: number[],
  vaultAuthority: PublicKey,
  vaultCreator: PublicKey,
) {
  const vault = PublicKey.findProgramAddressSync(
    [Buffer.from("vault"), Buffer.from(id)],
    program.programId,
  )[0];

  return {
    vault,
    request: program.methods.initVault(id, vaultAuthority).accountsPartial({
      vault,
      vaultConfig,
      vaultCreator,
      systemProgram: SystemProgram.programId,
    }),
  };
}

function claimRecordPda(vault: PublicKey, claimant: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("claim"), vault.toBuffer(), claimant.toBuffer()],
    program.programId,
  )[0];
}

const unauthorized = Keypair.generate();
const unauthorizedAirdrop = await connection.requestAirdrop(
  unauthorized.publicKey,
  1_000_000_000,
);
await connection.confirmTransaction(unauthorizedAirdrop, "confirmed");
const vaultCreator = Keypair.generate();
const vaultCreatorAirdrop = await connection.requestAirdrop(
  vaultCreator.publicKey,
  1_000_000_000,
);
await connection.confirmTransaction(vaultCreatorAirdrop, "confirmed");

await waitForProgramExecution(
  () =>
    program.methods
      .initializeVaultConfig(vaultCreator.publicKey)
    .accountsPartial({
        vaultConfig,
        authority: unauthorized.publicKey,
        program: program.programId,
        programData,
        systemProgram: SystemProgram.programId,
      })
      .signers([unauthorized])
      .rpc(),
  "Unauthorized",
);

await program.methods
  .initializeVaultConfig(wallet.publicKey)
  .accountsPartial({
    vaultConfig,
    authority: wallet.publicKey,
    program: program.programId,
    programData,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

await expectAnchorError(
  program.methods
    .setVaultCreator(vaultCreator.publicKey)
    .accountsPartial({
      vaultConfig,
      authority: unauthorized.publicKey,
      program: program.programId,
      programData,
    })
    .signers([unauthorized])
    .rpc(),
  "Unauthorized",
);

await program.methods
  .setVaultCreator(vaultCreator.publicKey)
  .accountsPartial({
    vaultConfig,
    authority: wallet.publicKey,
    program: program.programId,
    programData,
  })
  .rpc();

const vaultConfigAccount = await program.account.vaultConfig.fetch(vaultConfig);
assert.equal(
  vaultConfigAccount.vaultCreator.toBase58(),
  vaultCreator.publicKey.toBase58(),
);

const zeroId = new Array<number>(32).fill(0);
const zeroVault = await initVault(zeroId, wallet.publicKey, vaultCreator.publicKey);
await waitForProgramExecution(
  () => zeroVault.request.signers([vaultCreator]).rpc(),
  "InvalidVaultId",
);

const operationalAuthority = Keypair.generate();
const unauthorizedVault = await initVault(
  vaultId("unauthorized-vault"),
  operationalAuthority.publicKey,
  unauthorized.publicKey,
);
await expectAnchorError(
  unauthorizedVault.request.signers([unauthorized]).rpc(),
  "Unauthorized",
);

const id = vaultId("local-smoke-test");
const { vault, request: initRequest } = await initVault(
  id,
  operationalAuthority.publicKey,
  vaultCreator.publicKey,
);
const invalidAuthorityId = vaultId("invalid-authority-vault");
const invalidAuthorityVault = await initVault(
  invalidAuthorityId,
  PublicKey.default,
  vaultCreator.publicKey,
);
await expectAnchorError(
  invalidAuthorityVault.request.signers([vaultCreator]).rpc(),
  "InvalidAuthority",
);

await initRequest.signers([vaultCreator]).rpc();
assert.equal(
  (await program.account.vault.fetch(vault)).authority.toBase58(),
  operationalAuthority.publicKey.toBase58(),
);

await expectAnchorError(
  program.methods
    .transferVaultAuthority(wallet.publicKey)
    .accountsPartial({ vault, authority: wallet.publicKey })
    .rpc(),
  "ConstraintHasOne",
);

await program.methods
  .transferVaultAuthority(wallet.publicKey)
  .accountsPartial({
    vault,
    authority: operationalAuthority.publicKey,
  })
  .signers([operationalAuthority])
  .rpc();
assert.equal(
  (await program.account.vault.fetch(vault)).authority.toBase58(),
  wallet.publicKey.toBase58(),
);


await expectAnchorError(
  program.methods
    .deposit(new BN(0))
    .accountsPartial({
      vault,
      authority: wallet.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .rpc(),
  "InvalidAmount",
);

const claimant = Keypair.generate();
const claimRecord = claimRecordPda(vault, claimant.publicKey);
await expectAnchorError(
  program.methods
    .setClaimable(new BN(1))
    .accountsPartial({
      vault,
      claimant: claimant.publicKey,
      claimRecord,
      authority: wallet.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .rpc(),
  "InvalidVaultStatus",
);

await expectAnchorError(
  program.methods
    .withdraw(new BN(1))
    .accountsPartial({
      vault,
      authority: wallet.publicKey,
      destination: wallet.publicKey,
    })
    .rpc(),
  "InvalidVaultStatus",
);

await expectAnchorError(
  program.methods
    .cleanupVault()
    .accountsPartial({
      vault,
      authority: wallet.publicKey,
      destination: wallet.publicKey,
    })
    .rpc(),
  "InvalidVaultStatus",
);

await expectAnchorError(
  program.methods
    .deposit(new BN(1))
    .accountsPartial({
      vault,
      authority: unauthorized.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .signers([unauthorized])
    .rpc(),
  "ConstraintHasOne",
);

await program.methods
  .deposit(new BN(1_000_000_000))
  .accountsPartial({
    vault,
    authority: wallet.publicKey,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

let vaultAccount = await program.account.vault.fetch(vault);
assert.equal(vaultAccount.totalDeposited.toString(), "1000000000");

await program.methods
  .closeVault()
  .accountsPartial({ vault, authority: wallet.publicKey })
  .rpc();

await expectAnchorError(
  program.methods
    .closeVault()
    .accountsPartial({ vault, authority: wallet.publicKey })
    .rpc(),
  "InvalidVaultStatus",
);

await expectAnchorError(
  program.methods
    .deposit(new BN(1))
    .accountsPartial({
      vault,
      authority: wallet.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .rpc(),
  "InvalidVaultStatus",
);

await expectAnchorError(
  program.methods
    .setClaimable(new BN(0))
    .accountsPartial({
      vault,
      claimant: claimant.publicKey,
      claimRecord,
      authority: wallet.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .rpc(),
  "InvalidAmount",
);

await program.methods
  .setClaimable(new BN(500_000_000))
  .accountsPartial({
    vault,
    claimant: claimant.publicKey,
    claimRecord,
    authority: wallet.publicKey,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

const unclaimedClaimant = Keypair.generate();
const unclaimedRecord = claimRecordPda(vault, unclaimedClaimant.publicKey);
await program.methods
  .setClaimable(new BN(600_000_000))
  .accountsPartial({
    vault,
    claimant: unclaimedClaimant.publicKey,
    claimRecord: unclaimedRecord,
    authority: wallet.publicKey,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

await program.methods
  .claim()
  .accountsPartial({
    vault,
    claimRecord,
    authority: wallet.publicKey,
    recipient: claimant.publicKey,
  })
  .rpc();

assert.equal(await connection.getBalance(claimant.publicKey), 500_000_000);
const claimAccount = await program.account.claimRecord.fetch(claimRecord);
assert.ok(claimAccount.claimedAt.toNumber() > 0);

await expectAnchorError(
  program.methods
    .claim()
    .accountsPartial({
      vault,
      claimRecord,
      authority: wallet.publicKey,
      recipient: claimant.publicKey,
    })
    .rpc(),
  "AlreadyClaimed",
);

await expectAnchorError(
  program.methods
    .claim()
    .accountsPartial({
      vault,
      claimRecord: unclaimedRecord,
      authority: wallet.publicKey,
      recipient: unclaimedClaimant.publicKey,
    })
    .rpc(),
  "InsufficientFunds",
);

await expectAnchorError(
  program.methods
    .cleanupVault()
    .accountsPartial({
      vault,
      authority: wallet.publicKey,
      destination: wallet.publicKey,
    })
    .rpc(),
  "VaultAccountingMismatch",
);

await expectAnchorError(
  program.methods
    .withdraw(new BN(0))
    .accountsPartial({
      vault,
      authority: wallet.publicKey,
      destination: wallet.publicKey,
    })
    .rpc(),
  "InvalidAmount",
);

await program.methods
  .withdraw(new BN(300_000_000))
  .accountsPartial({
    vault,
    authority: wallet.publicKey,
    destination: wallet.publicKey,
  })
  .rpc();

await program.methods
  .withdrawAll()
  .accountsPartial({
    vault,
    authority: wallet.publicKey,
    destination: wallet.publicKey,
  })
  .rpc();

vaultAccount = await program.account.vault.fetch(vault);
assert.equal(vaultAccount.totalClaimed.toString(), "500000000");
assert.equal(vaultAccount.totalWithdrawn.toString(), "500000000");

await provider.sendAndConfirm(
  new Transaction().add(
    SystemProgram.transfer({
      fromPubkey: wallet.publicKey,
      toPubkey: vault,
      lamports: 1_234,
    }),
  ),
);

await expectAnchorError(
  program.methods
    .cleanupClaimRecord()
    .accountsPartial({ claimRecord, signer: unauthorized.publicKey })
    .signers([unauthorized])
    .rpc(),
  "InvalidClaimRecord",
);

await program.methods
  .cleanupClaimRecord()
  .accountsPartial({ claimRecord: unclaimedRecord, signer: wallet.publicKey })
  .rpc();

await program.methods
  .cleanupClaimRecord()
  .accountsPartial({ claimRecord, signer: claimant.publicKey })
  .signers([claimant])
  .rpc();

await program.methods
  .cleanupVault()
  .accountsPartial({
    vault,
    authority: wallet.publicKey,
    destination: wallet.publicKey,
  })
  .rpc();

assert.equal(await program.account.claimRecord.fetchNullable(claimRecord), null);
assert.equal(await program.account.vault.fetchNullable(vault), null);

console.log(
  "  ✓ Authorization, validation, accounting, lifecycle, and cleanup checks passed",
);
