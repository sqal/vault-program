import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { AnchorProvider, BN, Program, Wallet } from "@anchor-lang/core";
import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
} from "@solana/web3.js";

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function vaultId(value: string): number[] {
  return [...createHash("sha256").update(value, "utf8").digest()];
}

async function expectAnchorError(
  promise: Promise<unknown>,
  expectedCode: string,
): Promise<void> {
  try {
    await promise;
  } catch (error) {
    const anchorError = error as {
      error?: { errorCode?: { code?: string } };
      errorCode?: { code?: string };
      logs?: string[];
      message?: string;
    };
    const details = [
      anchorError.error?.errorCode?.code,
      anchorError.errorCode?.code,
      anchorError.message,
      ...(anchorError.logs ?? []),
    ]
      .filter(Boolean)
      .join("\n");
    assert.match(details, new RegExp(`\\b${expectedCode}\\b`));
    return;
  }

  assert.fail(`Expected Anchor error ${expectedCode}`);
}

const rpcUrl = requiredEnv("RPC_URL");
const walletPath = requiredEnv("TEST_WALLET_PATH");
const idlPath = requiredEnv("TEST_IDL_PATH");
const wallet = new Wallet(
  Keypair.fromSecretKey(
    new Uint8Array(JSON.parse(readFileSync(walletPath, "utf8"))),
  ),
);
const connection = new Connection(rpcUrl, "confirmed");
const provider = new AnchorProvider(connection, wallet, {
  commitment: "confirmed",
});
const idl = JSON.parse(readFileSync(idlPath, "utf8"));
const program = new Program(idl, provider);
const programData = PublicKey.findProgramAddressSync(
  [program.programId.toBuffer()],
  new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111"),
)[0];

async function initVault(id: number[], authority = wallet.publicKey) {
  const vault = PublicKey.findProgramAddressSync(
    [Buffer.from("vault"), Buffer.from(id)],
    program.programId,
  )[0];

  return {
    vault,
    request: program.methods.initVault(id).accounts({
      vault,
      authority,
      program: program.programId,
      programData,
      systemProgram: SystemProgram.programId,
    }),
  };
}

const zeroId = new Array<number>(32).fill(0);
const zeroVault = await initVault(zeroId);
await expectAnchorError(zeroVault.request.rpc(), "InvalidVaultId");

const unauthorized = Keypair.generate();
const unauthorizedAirdrop = await connection.requestAirdrop(
  unauthorized.publicKey,
  1_000_000_000,
);
await connection.confirmTransaction(unauthorizedAirdrop, "confirmed");
const unauthorizedVault = await initVault(
  vaultId("unauthorized-vault"),
  unauthorized.publicKey,
);
await expectAnchorError(
  unauthorizedVault.request.signers([unauthorized]).rpc(),
  "Unauthorized",
);

const id = vaultId("local-smoke-test");
const { vault, request: initRequest } = await initVault(id);
await initRequest.rpc();

await program.methods
  .deposit(new BN(1_000_000_000))
  .accounts({
    vault,
    authority: wallet.publicKey,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

let vaultAccount: any = await program.account.vault.fetch(vault);
assert.equal(vaultAccount.totalDeposited.toString(), "1000000000");

await program.methods
  .closeVault()
  .accounts({ vault, authority: wallet.publicKey })
  .rpc();

await expectAnchorError(
  program.methods
    .deposit(new BN(1))
    .accounts({
      vault,
      authority: wallet.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .rpc(),
  "InvalidVaultStatus",
);

const claimant = Keypair.generate();
const claimRecord = PublicKey.findProgramAddressSync(
  [Buffer.from("claim"), vault.toBuffer(), claimant.publicKey.toBuffer()],
  program.programId,
)[0];

await program.methods
  .setClaimable(new BN(500_000_000))
  .accounts({
    vault,
    claimant: claimant.publicKey,
    claimRecord,
    authority: wallet.publicKey,
    systemProgram: SystemProgram.programId,
  })
  .rpc();

await program.methods
  .claim()
  .accounts({
    vault,
    claimRecord,
    authority: wallet.publicKey,
    recipient: claimant.publicKey,
  })
  .rpc();

assert.equal(await connection.getBalance(claimant.publicKey), 500_000_000);
const claimAccount: any = await program.account.claimRecord.fetch(claimRecord);
assert.ok(claimAccount.claimedAt.toNumber() > 0);

await expectAnchorError(
  program.methods
    .claim()
    .accounts({
      vault,
      claimRecord,
      authority: wallet.publicKey,
      recipient: claimant.publicKey,
    })
    .rpc(),
  "AlreadyClaimed",
);

await program.methods
  .withdrawAll()
  .accounts({
    vault,
    authority: wallet.publicKey,
    destination: wallet.publicKey,
  })
  .rpc();

vaultAccount = await program.account.vault.fetch(vault);
assert.equal(vaultAccount.totalClaimed.toString(), "500000000");
assert.equal(vaultAccount.totalWithdrawn.toString(), "500000000");

await program.methods
  .cleanupClaimRecord()
  .accounts({ claimRecord, signer: claimant.publicKey })
  .signers([claimant])
  .rpc();

await program.methods
  .cleanupVault()
  .accounts({
    vault,
    authority: wallet.publicKey,
    destination: wallet.publicKey,
  })
  .rpc();

assert.equal(await program.account.claimRecord.fetchNullable(claimRecord), null);
assert.equal(await program.account.vault.fetchNullable(vault), null);

console.log(
  "  ✓ Authorization, validation, lifecycle, and cleanup checks passed",
);
