set dotenv-load := true

# Enter the reproducible development environment.
shell:
    nix develop

# Format and test the Rust workspace.
rust-check:
    cargo fmt --all -- --check
    cargo test --workspace

# Run Solidity contract tests.
contract-test:
    base-forge test --root contracts

# Deploy and exercise every public registry call against a local Base-compatible node.
contract-smoke:
    scripts/smoke-test-base-anvil.sh

# End-to-end contract integration test (the smoke-test name is retained for compatibility).
contract-integration:
    scripts/smoke-test-base-anvil.sh

# Print integration-test actions, transaction hashes, and state reads.
contract-integration-verbose:
    INTEGRATION_VERBOSE=1 scripts/smoke-test-base-anvil.sh

# Run the same lifecycle on Base Sepolia. Deploys a new contract and spends test ETH.
contract-integration-base-sepolia:
    scripts/smoke-test-base-anvil.sh --base-sepolia

# Deploy to Base Sepolia. Requires BASE_SEPOLIA_RPC_URL and DEPLOYER_PRIVATE_KEY.
deploy-base-sepolia:
    scripts/deploy-base-sepolia.sh

# Execute all repository checks.
check: rust-check contract-test contract-smoke
