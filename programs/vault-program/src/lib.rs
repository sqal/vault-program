use anchor_lang::prelude::*;
use anchor_lang::system_program;

// This committed placeholder is replaced only in the deploy script's disposable
// build copy. See docs/deploy.md.
declare_id!("11111111111111111111111111111111");

const VAULT_ACCOUNT_SPACE: usize = 8 + 32 + 32 + 1 + 8 + 8 + 8 + 1;
const CLAIM_RECORD_SPACE: usize = 8 + 32 + 32 + 32 + 8 + 8 + 1;

#[program]
pub mod vault_program {
    use super::*;

    pub fn init_vault(ctx: Context<InitVault>, vault_id: [u8; 32]) -> Result<()> {
        require!(vault_id != [0u8; 32], VaultError::InvalidVaultId);

        let vault = &mut ctx.accounts.vault;
        vault.authority = ctx.accounts.authority.key();
        vault.vault_id = vault_id;
        vault.status = VaultStatus::Open;
        vault.total_deposited = 0;
        vault.total_claimed = 0;
        vault.total_withdrawn = 0;
        vault.bump = ctx.bumps.vault;

        emit!(VaultInitialized {
            vault_id,
            authority: vault.authority,
        });

        Ok(())
    }

    pub fn deposit(ctx: Context<Deposit>, amount: u64) -> Result<()> {
        require!(amount > 0, VaultError::InvalidAmount);
        require!(
            ctx.accounts.vault.status == VaultStatus::Open,
            VaultError::InvalidVaultStatus
        );

        system_program::transfer(
            CpiContext::new(
                ctx.accounts.system_program.key(),
                system_program::Transfer {
                    from: ctx.accounts.authority.to_account_info(),
                    to: ctx.accounts.vault.to_account_info(),
                },
            ),
            amount,
        )?;

        let vault = &mut ctx.accounts.vault;
        vault.total_deposited = vault
            .total_deposited
            .checked_add(amount)
            .ok_or(VaultError::Overflow)?;

        emit!(VaultDeposited {
            vault_id: vault.vault_id,
            amount,
            total_deposited: vault.total_deposited,
        });

        Ok(())
    }

    pub fn close_vault(ctx: Context<CloseVault>) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        require!(
            vault.status == VaultStatus::Open,
            VaultError::InvalidVaultStatus
        );

        vault.status = VaultStatus::Closed;

        emit!(VaultClosed {
            vault_id: vault.vault_id,
        });

        Ok(())
    }

    pub fn set_claimable(ctx: Context<SetClaimable>, amount: u64) -> Result<()> {
        require!(amount > 0, VaultError::InvalidAmount);
        require!(
            ctx.accounts.vault.status == VaultStatus::Closed,
            VaultError::InvalidVaultStatus
        );

        let claim_record = &mut ctx.accounts.claim_record;
        claim_record.vault = ctx.accounts.vault.key();
        claim_record.authority = ctx.accounts.authority.key();
        claim_record.claimant = ctx.accounts.claimant.key();
        claim_record.amount = amount;
        claim_record.claimed_at = 0;
        claim_record.bump = ctx.bumps.claim_record;

        emit!(ClaimableSet {
            vault_id: ctx.accounts.vault.vault_id,
            claimant: claim_record.claimant,
            amount,
        });

        Ok(())
    }

    pub fn claim(ctx: Context<Claim>) -> Result<()> {
        require!(
            ctx.accounts.vault.status == VaultStatus::Closed,
            VaultError::InvalidVaultStatus
        );

        let claim_record = &mut ctx.accounts.claim_record;
        require!(
            claim_record.vault == ctx.accounts.vault.key(),
            VaultError::InvalidClaimRecord
        );
        require!(
            claim_record.claimant == ctx.accounts.recipient.key(),
            VaultError::InvalidClaimRecord
        );
        require!(claim_record.claimed_at == 0, VaultError::AlreadyClaimed);
        require!(claim_record.amount > 0, VaultError::NothingToClaim);

        let total_outflow = ctx
            .accounts
            .vault
            .total_claimed
            .checked_add(ctx.accounts.vault.total_withdrawn)
            .ok_or(VaultError::Overflow)?;
        let remaining = ctx
            .accounts
            .vault
            .total_deposited
            .checked_sub(total_outflow)
            .ok_or(VaultError::InsufficientFunds)?;
        require!(
            claim_record.amount <= remaining,
            VaultError::InsufficientFunds
        );

        let vault_info = ctx.accounts.vault.to_account_info();
        let recipient_info = ctx.accounts.recipient.to_account_info();
        let available = available_vault_lamports(&vault_info)?;
        require!(
            claim_record.amount <= available,
            VaultError::InsufficientFunds
        );

        transfer_lamports(&vault_info, &recipient_info, claim_record.amount)?;

        claim_record.claimed_at = Clock::get()?.unix_timestamp;

        let vault = &mut ctx.accounts.vault;
        vault.total_claimed = vault
            .total_claimed
            .checked_add(claim_record.amount)
            .ok_or(VaultError::Overflow)?;

        emit!(Claimed {
            vault_id: vault.vault_id,
            claimant: claim_record.claimant,
            amount: claim_record.amount,
        });

        Ok(())
    }

    pub fn withdraw(ctx: Context<Withdraw>, amount: u64) -> Result<()> {
        require!(amount > 0, VaultError::InvalidAmount);
        require!(
            ctx.accounts.vault.status == VaultStatus::Closed,
            VaultError::InvalidVaultStatus
        );

        let vault_info = ctx.accounts.vault.to_account_info();
        let available = available_vault_lamports(&vault_info)?;
        require!(amount <= available, VaultError::InsufficientFunds);

        transfer_lamports(
            &vault_info,
            &ctx.accounts.destination.to_account_info(),
            amount,
        )?;

        let vault = &mut ctx.accounts.vault;
        vault.record_withdrawal(amount)?;

        emit!(Withdrawn {
            vault_id: vault.vault_id,
            amount,
            destination: ctx.accounts.destination.key(),
        });

        Ok(())
    }

    pub fn withdraw_all(ctx: Context<WithdrawAll>) -> Result<()> {
        require!(
            ctx.accounts.vault.status == VaultStatus::Closed,
            VaultError::InvalidVaultStatus
        );

        let vault_info = ctx.accounts.vault.to_account_info();
        let amount = available_vault_lamports(&vault_info)?;
        require!(amount > 0, VaultError::NothingToWithdraw);

        transfer_lamports(
            &vault_info,
            &ctx.accounts.destination.to_account_info(),
            amount,
        )?;

        let vault = &mut ctx.accounts.vault;
        vault.record_withdrawal(amount)?;

        emit!(Withdrawn {
            vault_id: vault.vault_id,
            amount,
            destination: ctx.accounts.destination.key(),
        });

        Ok(())
    }

    pub fn cleanup_vault(ctx: Context<CleanupVault>) -> Result<()> {
        require!(
            ctx.accounts.vault.status == VaultStatus::Closed,
            VaultError::InvalidVaultStatus
        );

        let tracked_outflow = ctx
            .accounts
            .vault
            .total_claimed
            .checked_add(ctx.accounts.vault.total_withdrawn)
            .ok_or(VaultError::Overflow)?;
        let tracked_remaining = ctx
            .accounts
            .vault
            .total_deposited
            .checked_sub(tracked_outflow)
            .ok_or(VaultError::VaultAccountingMismatch)?;
        require!(tracked_remaining == 0, VaultError::VaultAccountingMismatch);

        let vault_info = ctx.accounts.vault.to_account_info();
        let available = available_vault_lamports(&vault_info)?;
        if available > 0 {
            transfer_lamports(
                &vault_info,
                &ctx.accounts.destination.to_account_info(),
                available,
            )?;
        }

        emit!(VaultCleanedUp {
            vault_id: ctx.accounts.vault.vault_id,
        });

        Ok(())
    }

    pub fn cleanup_claim_record(ctx: Context<CleanupClaimRecord>) -> Result<()> {
        let claim = &ctx.accounts.claim_record;
        let signer = ctx.accounts.signer.key();

        if claim.claimed_at != 0 {
            require!(signer == claim.claimant, VaultError::InvalidClaimRecord);
        } else {
            require!(signer == claim.authority, VaultError::Unauthorized);
        }

        emit!(ClaimRecordCleanedUp {
            vault: claim.vault,
            claimant: claim.claimant,
        });

        Ok(())
    }
}

#[account]
pub struct Vault {
    pub authority: Pubkey,
    pub vault_id: [u8; 32],
    pub status: VaultStatus,
    pub total_deposited: u64,
    pub total_claimed: u64,
    pub total_withdrawn: u64,
    pub bump: u8,
}

impl Vault {
    fn record_withdrawal(&mut self, amount: u64) -> Result<()> {
        let accounted_remaining = self
            .total_deposited
            .saturating_sub(self.total_claimed.saturating_add(self.total_withdrawn));
        let accounted_part = amount.min(accounted_remaining);
        self.total_withdrawn = self
            .total_withdrawn
            .checked_add(accounted_part)
            .ok_or(VaultError::Overflow)?;
        Ok(())
    }
}

#[account]
pub struct ClaimRecord {
    pub vault: Pubkey,
    pub authority: Pubkey,
    pub claimant: Pubkey,
    pub amount: u64,
    pub claimed_at: i64,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq)]
pub enum VaultStatus {
    Open,
    Closed,
}

#[event]
pub struct VaultInitialized {
    pub vault_id: [u8; 32],
    pub authority: Pubkey,
}

#[event]
pub struct VaultDeposited {
    pub vault_id: [u8; 32],
    pub amount: u64,
    pub total_deposited: u64,
}

#[event]
pub struct VaultClosed {
    pub vault_id: [u8; 32],
}

#[event]
pub struct ClaimableSet {
    pub vault_id: [u8; 32],
    pub claimant: Pubkey,
    pub amount: u64,
}

#[event]
pub struct Claimed {
    pub vault_id: [u8; 32],
    pub claimant: Pubkey,
    pub amount: u64,
}

#[event]
pub struct Withdrawn {
    pub vault_id: [u8; 32],
    pub amount: u64,
    pub destination: Pubkey,
}

#[event]
pub struct VaultCleanedUp {
    pub vault_id: [u8; 32],
}

#[event]
pub struct ClaimRecordCleanedUp {
    pub vault: Pubkey,
    pub claimant: Pubkey,
}

#[derive(Accounts)]
#[instruction(vault_id: [u8; 32])]
pub struct InitVault<'info> {
    #[account(
        init,
        payer = authority,
        space = VAULT_ACCOUNT_SPACE,
        seeds = [b"vault".as_ref(), vault_id.as_ref()],
        bump
    )]
    pub vault: Account<'info, Vault>,

    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(
        constraint = program.programdata_address()? == Some(program_data.key()) @ VaultError::Unauthorized
    )]
    pub program: Program<'info, crate::program::VaultProgram>,

    #[account(
        constraint = program_data.upgrade_authority_address.is_some() @ VaultError::Unauthorized,
        constraint = program_data.upgrade_authority_address == Some(authority.key()) @ VaultError::Unauthorized
    )]
    pub program_data: Account<'info, ProgramData>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Deposit<'info> {
    #[account(
        mut,
        seeds = [b"vault".as_ref(), vault.vault_id.as_ref()],
        bump = vault.bump,
        has_one = authority
    )]
    pub vault: Account<'info, Vault>,

    #[account(mut)]
    pub authority: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CloseVault<'info> {
    #[account(
        mut,
        seeds = [b"vault".as_ref(), vault.vault_id.as_ref()],
        bump = vault.bump,
        has_one = authority
    )]
    pub vault: Account<'info, Vault>,

    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct SetClaimable<'info> {
    #[account(
        mut,
        seeds = [b"vault".as_ref(), vault.vault_id.as_ref()],
        bump = vault.bump,
        has_one = authority
    )]
    pub vault: Account<'info, Vault>,

    /// CHECK: claimant address only used in PDA seed + persisted in claim record.
    pub claimant: UncheckedAccount<'info>,

    #[account(
        init,
        payer = authority,
        space = CLAIM_RECORD_SPACE,
        seeds = [b"claim".as_ref(), vault.key().as_ref(), claimant.key().as_ref()],
        bump
    )]
    pub claim_record: Account<'info, ClaimRecord>,

    #[account(mut)]
    pub authority: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Claim<'info> {
    #[account(
        mut,
        seeds = [b"vault".as_ref(), vault.vault_id.as_ref()],
        bump = vault.bump,
        has_one = authority
    )]
    pub vault: Account<'info, Vault>,

    #[account(
        mut,
        seeds = [b"claim".as_ref(), vault.key().as_ref(), recipient.key().as_ref()],
        bump = claim_record.bump
    )]
    pub claim_record: Account<'info, ClaimRecord>,

    pub authority: Signer<'info>,

    #[account(mut)]
    pub recipient: SystemAccount<'info>,
}

#[derive(Accounts)]
pub struct Withdraw<'info> {
    #[account(
        mut,
        seeds = [b"vault".as_ref(), vault.vault_id.as_ref()],
        bump = vault.bump,
        has_one = authority
    )]
    pub vault: Account<'info, Vault>,

    pub authority: Signer<'info>,

    #[account(mut)]
    pub destination: SystemAccount<'info>,
}

#[derive(Accounts)]
pub struct WithdrawAll<'info> {
    #[account(
        mut,
        seeds = [b"vault".as_ref(), vault.vault_id.as_ref()],
        bump = vault.bump,
        has_one = authority
    )]
    pub vault: Account<'info, Vault>,

    pub authority: Signer<'info>,

    #[account(mut)]
    pub destination: SystemAccount<'info>,
}

#[derive(Accounts)]
pub struct CleanupVault<'info> {
    #[account(
        mut,
        close = destination,
        seeds = [b"vault".as_ref(), vault.vault_id.as_ref()],
        bump = vault.bump,
        has_one = authority
    )]
    pub vault: Account<'info, Vault>,

    pub authority: Signer<'info>,

    #[account(mut)]
    pub destination: SystemAccount<'info>,
}

#[derive(Accounts)]
pub struct CleanupClaimRecord<'info> {
    #[account(
        mut,
        close = signer,
        seeds = [b"claim".as_ref(), claim_record.vault.as_ref(), claim_record.claimant.as_ref()],
        bump = claim_record.bump
    )]
    pub claim_record: Account<'info, ClaimRecord>,

    #[account(mut)]
    pub signer: Signer<'info>,
}

#[error_code]
pub enum VaultError {
    #[msg("Invalid vault ID")]
    InvalidVaultId,
    #[msg("Invalid amount")]
    InvalidAmount,
    #[msg("Vault is not in the correct status for this operation")]
    InvalidVaultStatus,
    #[msg("Insufficient funds in vault")]
    InsufficientFunds,
    #[msg("Arithmetic overflow")]
    Overflow,
    #[msg("Payout already claimed")]
    AlreadyClaimed,
    #[msg("Claim record does not match expected claimant")]
    InvalidClaimRecord,
    #[msg("Nothing to claim")]
    NothingToClaim,
    #[msg("Nothing to withdraw")]
    NothingToWithdraw,
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Vault accounting mismatch")]
    VaultAccountingMismatch,
}

fn available_vault_lamports(vault_info: &AccountInfo) -> Result<u64> {
    let rent_exempt_minimum = Rent::get()?.minimum_balance(VAULT_ACCOUNT_SPACE);
    Ok(vault_info.lamports().saturating_sub(rent_exempt_minimum))
}

fn transfer_lamports(from: &AccountInfo, to: &AccountInfo, amount: u64) -> Result<()> {
    let mut from_lamports = from.try_borrow_mut_lamports()?;
    let next_from = (**from_lamports)
        .checked_sub(amount)
        .ok_or(VaultError::InsufficientFunds)?;
    **from_lamports = next_from;
    drop(from_lamports);

    let mut to_lamports = to.try_borrow_mut_lamports()?;
    let next_to = (**to_lamports)
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    **to_lamports = next_to;

    Ok(())
}
