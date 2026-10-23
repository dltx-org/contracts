// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccount, Withdrawal} from "../src/DepositAccount.sol";
import {DepositAccountState} from "../src/DepositAccountState.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Helpers, MockPool, MockToken, MockTokenMessenger} from "./Helpers.sol";

/*
 * The money (spec §8.2): the withdrawal and its escape hatch, the owner's flat exit fee (amendment E), funding an
 * authorised vault, the conversion. No fork: Arbitrum's pinned USDC, USDT0, pool and Circle's
 * TokenMessengerV2 are mocks etched at their addresses (the fork tests use the real ones).
 */
contract MoneyTest is Helpers {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant POOL = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    address constant TM = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant VAULT = address(0x7A017);

    DepositFactory f;
    DepositAccount a;

    function setUp() public virtual {
        vm.chainId(42161);
        f = deployFactory();
        vm.startPrank(RECOVERY);
        f.setTransferKey(TRANSFER);
        f.setFeeRecipient(FEES);
        vm.stopPrank();
        a = deployTwo(f, ALICE, WALLET_A, passkey(PASSKEY_A));
        vm.etch(USDC, address(new MockToken()).code);
        vm.etch(USDT, address(new MockToken()).code);
        vm.etch(POOL, address(new MockPool()).code);
        vm.etch(TM, address(new MockTokenMessenger()).code);
        MockPool(POOL).init(USDC, USDT); // token0 USDC (the lower address), as the real pool
        MockPool(POOL).setRate(10_000); // etched code ran no constructor
        MockToken(USDC).mint(POOL, 1_000_000e6);
        MockToken(USDC).mint(address(a), 1_000e6);
        MockToken(USDT).mint(address(a), 1_000e6);
    }

    function usdc(address who) internal view returns (uint256) {
        return MockToken(USDC).balanceOf(who);
    }

    /// The first withdrawal address, in effect after its 24 hours (decision 32).
    function withAddress() internal {
        setWithdrawalNow(a, PASSKEY_A, DEST);
    }

    // ── withdraw: only to the withdrawal address ─────────────────────────────────────────────

    /// The owner's own exit pays the flat 1 USD fee (amendment E).
    function test_aWalletCredentialWithdrawsToTheWithdrawalAddress() public {
        withAddress();
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDC, 100e6);
        assertEq(usdc(DEST), 99e6);
        assertEq(usdc(FEES), 1e6);
        assertEq(usdc(address(a)), 900e6);
    }

    function test_theTransferKeyWithdrawsWithNoFeeUnlessRevoked() public {
        withAddress();
        vm.prank(TRANSFER);
        a.withdraw(USDC, 100e6);
        assertEq(usdc(DEST), 100e6);
        assertEq(usdc(FEES), 0);
        (uint256 nonce, uint256 deadline, bytes memory sig) = revokeSig(a, PASSKEY_A, true);
        a.revokeTransfer(nonce, deadline, sig);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        a.withdraw(USDC, 100e6);
        (nonce, deadline, sig) = revokeSig(a, WALLET_A, false);
        a.allowTransfer(nonce, deadline, sig);
        vm.prank(TRANSFER);
        a.withdraw(USDC, 100e6);
        assertEq(usdc(DEST), 200e6);
    }

    function test_nobodyElseWithdrawsBeforeTheHatchOpens() public {
        withAddress();
        address[3] memory others = [STRANGER, RECOVERY, vm.addr(WALLET_B)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(DepositAccountState.NotAllowed.selector);
            a.withdraw(USDC, 1e6);
        }
    }

    /// Decision 17: 7 days without the transfer key's check-in, anyone runs the withdrawal, which
    /// still pays only the withdrawal address.
    function test_theEscapeHatchOpensAfterSevenDaysWithoutACheckIn() public {
        withAddress();
        vm.prank(TRANSFER);
        f.checkIn(supported());
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        a.withdraw(USDC, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(STRANGER);
        a.withdraw(USDC, 1_000e6);
        assertEq(usdc(DEST), 1_000e6);
        assertEq(usdc(STRANGER), 0);
        vm.prank(STRANGER);
        a.withdraw(USDT, 1_000e6);
        assertEq(MockToken(USDT).balanceOf(DEST), 1_000e6);
    }

    function test_aRevokedTransferKeyDoesNotCloseTheHatch() public {
        withAddress();
        (uint256 nonce, uint256 deadline, bytes memory sig) = revokeSig(a, PASSKEY_A, true);
        a.revokeTransfer(nonce, deadline, sig);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(STRANGER);
        a.withdraw(USDC, 10e6);
        assertEq(usdc(DEST), 10e6);
    }

    function test_noWithdrawalWithoutAnAddress() public {
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.NoWithdrawalAddress.selector);
        a.withdraw(USDC, 1e6);
    }

    /// A pending change pays nothing to its address until its 24 hours pass.
    function test_aPendingAddressIsPaidOnlyOnceInEffect() public {
        withAddress();
        setWithdrawal(a, WALLET_A, DEST2);
        vm.prank(TRANSFER);
        a.withdraw(USDC, 1e6);
        assertEq(usdc(DEST), 1e6);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(TRANSFER);
        a.withdraw(USDC, 1e6);
        assertEq(usdc(DEST2), 1e6);
    }

    function test_theNativeCoinGoesToTheWithdrawalAddressToo() public {
        withAddress();
        vm.deal(address(a), 1 ether);
        vm.prank(TRANSFER);
        a.withdraw(address(0), 1 ether);
        assertEq(DEST.balance, 1 ether);
        (bool ok,) = address(a).call{value: 1}("");
        assertFalse(ok, "a deployed account refuses a plain send");
    }

    function test_aTokenWithNoReturnValueWithdraws() public {
        withAddress();
        MockToken(USDT).setQuiet(true);
        vm.prank(TRANSFER);
        a.withdraw(USDT, 5e6);
        assertEq(MockToken(USDT).balanceOf(DEST), 5e6);
    }

    // ── the owner's exits and the flat fee (decision 19, amendment E) ──────────────────────────

    function test_theFeeIsOneUsdCompiled() public view {
        assertEq(a.EXIT_FEE(), 1e6);
    }

    function test_aSignedWithdrawalPaysTheFlatFeeAndIsConsumedOnce() public {
        withAddress();
        Withdrawal memory w = withdrawal(a, USDC, 100e6, 1e6);
        bytes memory sig = signWithdrawal(a, PASSKEY_A, w);
        vm.prank(STRANGER); // anyone submits; the second argument is ignored
        a.withdrawSigned(w, 0, sig);
        assertEq(usdc(DEST), 99e6);
        assertEq(usdc(FEES), 1e6);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BadNonce.selector);
        a.withdrawSigned(w, 0, sig);
    }

    /// The owner signs at least the fee; every field is signed.
    function test_theFeeMustBeSignedAndEveryFieldIsBound() public {
        withAddress();
        Withdrawal memory w = withdrawal(a, USDC, 100e6, 1e6 - 1);
        bytes memory sig = signWithdrawal(a, WALLET_A, w);
        vm.expectRevert(DepositAccountState.FeeAboveMax.selector);
        a.withdrawSigned(w, 0, sig);
        w = withdrawal(a, USDC, 100e6, 1e6);
        sig = signWithdrawal(a, WALLET_A, w);
        vm.startPrank(TRANSFER);
        Withdrawal memory other = w;
        other.maxFee = 2e6; // a larger max: not what was signed
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        a.withdrawSigned(other, 0, sig);
        other = withdrawal(a, USDC, 101e6, 1e6);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        a.withdrawSigned(other, 0, sig);
        other = withdrawal(a, USDT, 100e6, 1e6);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        a.withdrawSigned(other, 0, sig);
        other = withdrawal(a, USDC, 100e6, 1e6);
        other.feeRecipient = STRANGER; // another fee recipient: not what was signed
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        a.withdrawSigned(other, 0, sig);
        vm.stopPrank();
    }

    /// The destination is signed: a withdrawal signed before an address change can't be played
    /// after it, to either address.
    function test_aSignedWithdrawalBindsTheWithdrawalAddress() public {
        withAddress();
        Withdrawal memory w = withdrawal(a, USDC, 100e6, 1e6);
        bytes memory sig = signWithdrawal(a, PASSKEY_A, w);
        setWithdrawal(a, WALLET_A, DEST2);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        w.deadline = vm.getBlockTimestamp() + 1 hours; // (the signature's own deadline would have passed)
        sig = signWithdrawal(a, PASSKEY_A, w);
        vm.expectRevert(DepositAccountState.NotWithdrawalAddress.selector);
        a.withdrawSigned(w, 0, sig);
        assertEq(usdc(DEST), 0);
        assertEq(usdc(DEST2), 0);
    }

    /// The fee recipient is signed: recovery changing it voids every signed withdrawal naming the old.
    function test_aSignedWithdrawalBindsTheFeeRecipient() public {
        withAddress();
        Withdrawal memory w = withdrawal(a, USDC, 100e6, 1e6);
        bytes memory sig = signWithdrawal(a, PASSKEY_A, w);
        vm.prank(RECOVERY);
        f.setFeeRecipient(STRANGER);
        vm.expectRevert(DepositAccountState.NotFeeRecipient.selector);
        a.withdrawSigned(w, 0, sig);
        assertEq(usdc(STRANGER), 0);
    }

    /// No fee recipient: no fee, all of it to the owner.
    function test_noFeeRecipientNoFee() public {
        withAddress();
        vm.prank(RECOVERY);
        f.setFeeRecipient(address(0));
        Withdrawal memory w = withdrawal(a, USDC, 10e6, 1e6);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));
        assertEq(usdc(DEST), 10e6);
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDC, 10e6);
        assertEq(usdc(DEST), 20e6);
    }

    /// A fee transfer that reverts (USDC blacklisting the fee address) never blocks the withdrawal:
    /// it proceeds without the fee, whole.
    function test_aBlockedFeeNeverBlocksTheWithdrawal() public {
        withAddress();
        vm.mockCallRevert(USDC, abi.encodeWithSelector(MockToken.transfer.selector, FEES, 1e6), "blacklisted");
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDC, 10e6);
        assertEq(usdc(DEST), 10e6);
        Withdrawal memory w = withdrawal(a, USDC, 10e6, 1e6);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));
        assertEq(usdc(DEST), 20e6);
        assertEq(usdc(FEES), 0);
        // a fee transfer that answers false: the same
        vm.clearMockedCalls();
        vm.mockCall(USDC, abi.encodeWithSelector(MockToken.transfer.selector, FEES, 1e6), abi.encode(false));
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDC, 10e6);
        assertEq(usdc(DEST), 30e6);
    }

    /// When a fee is due, an amount at or below it is refused: nothing moves, the money stays. Above
    /// it, the rest leaves (1.01 USD: 0.01 to the owner). With no fee due, any amount leaves.
    function test_anAmountAtOrBelowADueFeeIsRefused() public {
        withAddress();
        vm.startPrank(vm.addr(WALLET_A));
        vm.expectRevert(DepositAccountState.AmountNotAboveFee.selector);
        a.withdraw(USDC, 1e6);
        vm.expectRevert(DepositAccountState.AmountNotAboveFee.selector);
        a.withdraw(USDC, 0.5e6);
        a.withdraw(USDC, 1.01e6);
        vm.stopPrank();
        assertEq(usdc(DEST), 0.01e6);
        assertEq(usdc(FEES), 1e6);
        Withdrawal memory w = withdrawal(a, USDC, 1e6, 1e6);
        bytes memory sig = signWithdrawal(a, PASSKEY_A, w);
        vm.expectRevert(DepositAccountState.AmountNotAboveFee.selector);
        a.withdrawSigned(w, 0, sig);
        // no fee recipient: no fee due, any amount
        vm.prank(RECOVERY);
        f.setFeeRecipient(address(0));
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDC, 0.5e6);
        assertEq(usdc(DEST), 0.51e6);
    }

    /// E4b (Codex's review): the WHOLE balance at or below the fee leaves free, by either owner path,
    /// so the owner can always empty the account without DLTX; part of it is still refused.
    function test_theWholeBalanceAtOrBelowTheFeeLeavesFree() public {
        withAddress();
        uint256 all = usdc(address(a));
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDC, all - 0.8e6);
        assertEq(usdc(address(a)), 0.8e6);
        uint256 dest = usdc(DEST);
        uint256 fees = usdc(FEES);
        vm.startPrank(vm.addr(WALLET_A));
        vm.expectRevert(DepositAccountState.AmountNotAboveFee.selector);
        a.withdraw(USDC, 0.5e6);
        a.withdraw(USDC, 0.8e6);
        vm.stopPrank();
        assertEq(usdc(address(a)), 0);
        assertEq(usdc(DEST), dest + 0.8e6);
        assertEq(usdc(FEES), fees);
        // signed: exactly the fee, the whole balance, leaves whole
        deal(USDC, address(a), 1e6);
        Withdrawal memory w = withdrawal(a, USDC, 1e6, 1e6);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));
        assertEq(usdc(address(a)), 0);
        assertEq(usdc(DEST), dest + 1.8e6);
        assertEq(usdc(FEES), fees);
    }

    /// One rule for every signature of USDC or USDT: a maximum of at least the fee, even when no fee
    /// turns out due (no recipient); signed again with it, it leaves whole.
    function test_theMaxFeeRuleHoldsEvenWithNoFeeDue() public {
        withAddress();
        vm.prank(RECOVERY);
        f.setFeeRecipient(address(0));
        Withdrawal memory w = withdrawal(a, USDC, 10e6, 0);
        bytes memory sig = signWithdrawal(a, PASSKEY_A, w);
        vm.expectRevert(DepositAccountState.FeeAboveMax.selector);
        a.withdrawSigned(w, 0, sig);
        w = withdrawal(a, USDC, 10e6, 1e6);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));
        assertEq(usdc(DEST), 10e6);
    }

    /// A failed fee says so: `Withdrawn` names the whole amount and a fee of zero.
    function test_aFailedFeeIsReportedAsNone() public {
        withAddress();
        vm.mockCallRevert(USDC, abi.encodeWithSelector(MockToken.transfer.selector, FEES, 1e6), "blacklisted");
        vm.expectEmit(address(a));
        emit DepositAccountState.Withdrawn(USDC, DEST, 10e6, 0, vm.addr(WALLET_A));
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDC, 10e6);
    }

    /// USDT with no return value (a quiet token) pays its fee like any other.
    function test_aQuietUsdtPaysTheFee() public {
        withAddress();
        MockToken(USDT).setQuiet(true);
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(USDT, 10e6);
        assertEq(MockToken(USDT).balanceOf(FEES), 1e6);
        assertEq(MockToken(USDT).balanceOf(DEST), 9e6);
    }

    /// The chain's pinned USDT (Arbitrum's USD₮0), 6 decimals as USDC: the same fee.
    function test_thePinnedUsdtPaysTheSameFee() public {
        withAddress();
        Withdrawal memory w = withdrawal(a, USDT, 100e6, 1e6);
        a.withdrawSigned(w, 0, signWithdrawal(a, WALLET_A, w));
        assertEq(MockToken(USDT).balanceOf(FEES), 1e6);
        assertEq(MockToken(USDT).balanceOf(DEST), 99e6);
    }

    /// No caller but the owner pays a fee: the transfer key's withdrawal and the escape hatch's are
    /// whole, so no one can turn the owner's money into fees a dollar at a time (amendment E).
    function test_onlyTheOwnersOwnExitPaysAFee() public {
        withAddress();
        vm.prank(TRANSFER);
        a.withdraw(USDC, 100e6);
        assertEq(usdc(DEST), 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days); // the hatch open
        for (uint256 i; i < 5; ++i) {
            vm.prank(STRANGER);
            a.withdraw(USDC, 1e6);
        }
        assertEq(usdc(DEST), 105e6);
        assertEq(usdc(FEES), 0);
    }

    /// Any other token pays no fee, whatever was signed: its units are not USDC's.
    function test_anotherTokenPaysNoFee() public {
        withAddress();
        MockToken other = new MockToken();
        other.mint(address(a), 100e18);
        Withdrawal memory w = withdrawal(a, address(other), 50e18, 0);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(address(other), 50e18);
        assertEq(other.balanceOf(DEST), 100e18);
        assertEq(other.balanceOf(FEES), 0);
    }

    /// The native coin pays no fee either, on a chain with a pinned USDT and on one without, where
    /// `conversionPool()` names the zero address as USDT (never the native coin's fee).
    function test_theNativeCoinPaysNoFee() public {
        withAddress();
        vm.deal(address(a), 2 ether);
        Withdrawal memory w = withdrawal(a, address(0), 1 ether, 0);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));

        vm.chainId(8453); // Base: no pinned USDT
        (, address usdt,) = a.conversionPool();
        assertEq(usdt, address(0));
        deliverRecord(a, 9, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A))); // a copy in sync
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(address(0), 1 ether);
        assertEq(DEST.balance, 2 ether);
        assertEq(FEES.balance, 0);
    }

    /// A passkey-only owner withdraws by signing, whatever the transfer key does.
    function test_aSignedWithdrawalWorksWithTheTransferKeyRevoked() public {
        withAddress();
        (uint256 nonce, uint256 deadline, bytes memory sig) = revokeSig(a, PASSKEY_A, true);
        a.revokeTransfer(nonce, deadline, sig);
        Withdrawal memory w = withdrawal(a, USDC, 10e6, 1e6);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));
        assertEq(usdc(DEST), 9e6);
    }

    function test_aSignedWithdrawalExpiresAndNamesItsChain() public {
        withAddress();
        Withdrawal memory w = withdrawal(a, USDC, 10e6, 1e6);
        bytes memory sig = signWithdrawal(a, WALLET_A, w);
        vm.chainId(1);
        deliverRecord(a, 1, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A))); // a copy in sync
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        a.withdrawSigned(w, 0, sig);
        vm.chainId(42161);
        vm.warp(w.deadline + 1);
        vm.expectRevert(DepositAccountState.Expired.selector);
        a.withdrawSigned(w, 0, sig);
    }

    // ── conversion (§8.2, decision 30) ───────────────────────────────────────────────────────

    function test_convertUsdtToUsdcOnThePinnedPool() public {
        vm.prank(TRANSFER);
        uint256 out = a.convertSwap(1_000e6, 0);
        assertEq(out, 1_000e6);
        assertEq(MockToken(USDT).balanceOf(address(a)), 0);
        assertEq(MockToken(USDT).balanceOf(POOL), 1_000e6);
        assertEq(usdc(address(a)), 2_000e6);
    }

    function test_theMinimumOutIsRaisedToTheBound() public {
        MockPool(POOL).setRate(9_979); // 997.9 per 1,000: below 1 USD less 0.2%
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BelowMinimum.selector);
        a.convertSwap(1_000e6, 0);
        MockPool(POOL).setRate(9_980); // exactly the floor, 998
        vm.prank(TRANSFER);
        assertEq(a.convertSwap(1_000e6, 0), 998e6);
        // a tighter minimum asked by the key is kept
        MockToken(USDT).mint(address(a), 1_000e6);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BelowMinimum.selector);
        a.convertSwap(1_000e6, 998.5e6);
    }

    function test_thePoolIsPaidOnlyTheAmountInAndOnlyDuringTheSwap() public {
        MockPool(POOL).setOvercharge(1);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BadAmount.selector);
        a.convertSwap(100e6, 0);
        vm.prank(POOL);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        a.uniswapV3SwapCallback(0, 100e6, "");
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        a.uniswapV3SwapCallback(0, 100e6, "");
    }

    function test_conversionNeedsTheTransferKeyAndAPinnedPool() public {
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        a.convertSwap(1e6, 0);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BadAmount.selector);
        a.convertSwap(1, 0); // a floor of zero
        vm.chainId(8453); // Base: no USDT, no pool
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.ConversionUnavailable.selector);
        a.convertSwap(1e6, 0);
        vm.chainId(10); // OP Mainnet: no pool holds liquidity (step 11e1 §15)
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.ConversionUnavailable.selector);
        a.convertSwap(1e6, 0);
        vm.chainId(42161);
        (uint256 nonce, uint256 deadline, bytes memory sig) = revokeSig(a, PASSKEY_A, true);
        a.revokeTransfer(nonce, deadline, sig);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        a.convertSwap(1e6, 0);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        a.convertBurn(1e6, 0);
    }

    function test_aBurnMintsToThisSameAddressOnADepositChain() public {
        vm.prank(TRANSFER);
        a.convertBurn(400e6, 0);
        MockTokenMessenger m = MockTokenMessenger(TM);
        assertEq(m.amount(), 400e6);
        assertEq(m.domain(), 0);
        assertEq(m.mintRecipient(), bytes32(uint256(uint160(address(a)))));
        assertEq(m.burnToken(), USDC);
        assertEq(m.destinationCaller(), bytes32(0));
        assertEq(m.maxFee(), 0);
        assertEq(m.threshold(), 2000);
        assertEq(usdc(address(a)), 600e6);
        assertEq(MockToken(USDC).allowance(address(a), TM), 0);
    }

    /// The messenger's minimum fee is read and passed as `maxFee` (a burn with 0 would revert where
    /// the controller raised it), up to the cap; above it, refused, the USDC kept.
    function test_aBurnPaysTheMessengersMinimumFeeUpToTheCap() public {
        MockTokenMessenger m = MockTokenMessenger(TM);
        m.setMinFee(true, 5_000); // 5 bp
        assertEq(a.burnMinFee(400e6), 0.2e6);
        vm.prank(TRANSFER);
        a.convertBurn(400e6, 0);
        assertEq(m.maxFee(), 0.2e6);
        assertEq(m.threshold(), 2000, "standard finality");
        m.setMinFee(true, 10_000); // 10 bp: the cap itself
        vm.prank(TRANSFER);
        a.convertBurn(100e6, 0);
        assertEq(m.maxFee(), 0.1e6);
        m.setMinFee(true, 10_001); // above the cap
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BurnFeeTooHigh.selector);
        a.convertBurn(100e6, 0);
        assertEq(usdc(address(a)), 500e6);
        m.setMinFee(false, 0); // no such function: 0
        assertEq(a.burnMinFee(100e6), 0);
    }

    /// HyperEVM (domain 19) is a deposit chain too: a burn mints to this same address there.
    function test_aBurnMintsToThisSameAddressOnHyperEvm() public {
        vm.prank(TRANSFER);
        a.convertBurn(250e6, 19);
        MockTokenMessenger m = MockTokenMessenger(TM);
        assertEq(m.amount(), 250e6);
        assertEq(m.domain(), 19);
        assertEq(m.mintRecipient(), bytes32(uint256(uint160(address(a)))));
        assertEq(m.burnToken(), USDC);
        assertEq(usdc(address(a)), 750e6);
    }

    /// Avalanche (domain 1) is a deposit chain (the operator's decision, 2026-10-20): a burn mints to
    /// this same address there.
    function test_aBurnMintsToThisSameAddressOnAvalanche() public {
        vm.prank(TRANSFER);
        a.convertBurn(250e6, 1);
        MockTokenMessenger m = MockTokenMessenger(TM);
        assertEq(m.amount(), 250e6);
        assertEq(m.domain(), 1);
        assertEq(m.mintRecipient(), bytes32(uint256(uint160(address(a)))));
        assertEq(m.burnToken(), USDC);
        assertEq(usdc(address(a)), 750e6);
    }

    /// On Avalanche the account burns its own USDC (Circle's native, the chain's pin) to the home,
    /// never to Avalanche itself; it has no conversion pool, and its USDC pays a capped fee.
    function test_onAvalancheTheAccountBurnsItsUsdcAndHasNoPool() public {
        address avaxUsdc = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        vm.chainId(43114);
        (address u, uint32 local) = a.cctpUsdc();
        assertEq(u, avaxUsdc);
        assertEq(local, 1);
        (address pool, address usdt,) = a.conversionPool();
        assertEq(pool, address(0));
        assertEq(usdt, address(0));
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.ConversionUnavailable.selector);
        a.convertSwap(1e6, 0);

        vm.etch(avaxUsdc, address(new MockToken()).code);
        MockToken(avaxUsdc).mint(address(a), 300e6);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BadDomain.selector); // its own
        a.convertBurn(100e6, 1);
        vm.prank(TRANSFER);
        a.convertBurn(100e6, 3);
        MockTokenMessenger m = MockTokenMessenger(TM);
        assertEq(m.domain(), 3);
        assertEq(m.burnToken(), avaxUsdc);
        assertEq(m.mintRecipient(), bytes32(uint256(uint160(address(a)))));
        assertEq(MockToken(avaxUsdc).balanceOf(address(a)), 200e6);

        // a signed withdrawal of Avalanche's USDC pays the flat fee (amendment E)
        deliverRecord(a, 9, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A))); // a copy in sync
        Withdrawal memory w = withdrawal(a, avaxUsdc, 200e6, 1e6);
        a.withdrawSigned(w, 0, signWithdrawal(a, PASSKEY_A, w));
        assertEq(MockToken(avaxUsdc).balanceOf(FEES), 1e6);
        assertEq(MockToken(avaxUsdc).balanceOf(DEST), 199e6);
    }

    function test_aBurnToItsOwnOrANonDepositDomainIsRefused() public {
        uint32[4] memory bad = [uint32(3), 5, 4, 17]; // its own; Solana, Noble, BNB Smart Chain (USYC only)
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(TRANSFER);
            vm.expectRevert(DepositAccountState.BadDomain.selector);
            a.convertBurn(1e6, bad[i]);
        }
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BadAmount.selector);
        a.convertBurn(0, 0);
    }
}
