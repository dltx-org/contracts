// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/// The long half's protocols on Arbitrum, pinned (spec §6; engine/evm/chains/42161.json): the vault
/// factory accepts a configuration only if it names exactly these, and the long half calls only these.
library Arbitrum {
    address internal constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD; // AAVE V3
    address internal constant ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7; // AAVE's oracle
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// Uniswap V3 WETH/USDC, fee 500: token0 WETH, token1 USDC.
    address internal constant SWAP_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    /// The repay-with-collateral receiver (contracts/repay-with-collateral), deployed 2026-10-07.
    address internal constant RECEIVER = 0xC69Ee59E3b0DbC99fA928B7674503b8A3f2CeEd0;
    /// AAVE's tokens for the two reserves (`getReserveData`, checked by the fork test).
    address internal constant A_WETH = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant VDEBT_USDC = 0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6;

    // ── amendment 2c: the rewards path (spec §3.2) ──────────────────────────────────────────────────
    /// AAVE's RewardsController (the reserves' `getIncentivesController()`).
    address internal constant REWARDS_CONTROLLER = 0x929EC64c34a17401F460460D4B9390518E5B473e;
    /// Merkl's distributor on Arbitrum.
    address internal constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    /// The pinned reward token, ARB, and its AAVE aToken (Merkl's AAVE campaigns paid aArbARB).
    address internal constant REWARD = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address internal constant A_REWARD = 0x6533afac2E7BCCB20dca161449A13A32D391fb00;
    /// Uniswap V3 ARB/USDC, fee 3,000: token0 ARB, token1 USDC.
    address internal constant REWARD_POOL = 0xaEBDcA1Bc8d89177EbE2308d62af5e74885DcCc3;
    /// Chainlink ARB / USD (8 decimals) and Arbitrum's sequencer uptime feed.
    address internal constant REWARD_FEED = 0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6;
    address internal constant SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
}
