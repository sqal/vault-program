#!/usr/bin/env bash

prepare_disposable_workspace() {
  local source_root="$1"
  local build_repo="$2"
  local build_cache="$3"

  mkdir -p \
    "$build_repo/programs/vault-program/src" \
    "$build_repo/target/deploy" \
    "$build_cache/debug" \
    "$build_cache/release"

  ln -s "$build_cache/debug" "$build_repo/target/debug"
  ln -s "$build_cache/release" "$build_repo/target/release"

  # The BPF artifact embeds `declare_id!`. Each disposable build may use a
  # different program keypair, so its BPF target must never be shared.

  cp "$source_root/Anchor.toml" "$build_repo/Anchor.toml"
  cp "$source_root/Cargo.toml" "$build_repo/Cargo.toml"
  cp "$source_root/Cargo.lock" "$build_repo/Cargo.lock"
  cp "$source_root/rust-toolchain.toml" "$build_repo/rust-toolchain.toml"
  cp "$source_root/programs/vault-program/Cargo.toml" \
    "$build_repo/programs/vault-program/Cargo.toml"
  cp "$source_root/programs/vault-program/src/lib.rs" \
    "$build_repo/programs/vault-program/src/lib.rs"
}
