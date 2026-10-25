// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

import {STEXAMM} from "src/STEXAMM.sol";
import {StepwiseFeeModule} from "src/swap-fee-modules/StepwiseFeeModule.sol";
import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {MockOverseer} from "src/mocks/sthype/MockOverseer.sol";
import {MockStHype} from "src/mocks/sthype/MockStHype.sol";

/// @dev Same minimal deployment as Amount0Deduction.t.sol.
///      Slashing is modelled as a real negative rebase: MockStHype balances are
///      shares * address(token0).balance / totalSupply, so cutting the native backing
///      by X% cuts every holder's balanceOf (incl. the pool's reserve0) by X%.
contract NegativeRebaseTest is Test {
    STEXAMM stex;
    StepwiseFeeModule swapFeeModule;
    stHYPEWithdrawalModule withdrawalModule;
    ISovereignPool pool;
    WETH weth;
    MockStHype token0;
    MockOverseer overseer;

    address owner = makeAddr("OWNER");
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");
    address trader = makeAddr("TRADER");

    uint256 aliceShares;
    uint256 bobShares;

    function setUp() public {
        token0 = new MockStHype();
        weth = new WETH();
        overseer = new MockOverseer(address(token0));

        ProtocolFactory protocolFactory = new ProtocolFactory(address(this));
        protocolFactory.setSovereignPoolFactory(address(new SovereignPoolFactory()));

        withdrawalModule = new stHYPEWithdrawalModule(address(overseer), makeAddr("WSTHYPE"), address(this));
        swapFeeModule = new StepwiseFeeModule(owner);

        stex = new STEXAMM(
            "Stake Exchange LP",
            "STEX LP",
            address(token0),
            address(weth),
            address(swapFeeModule),
            address(protocolFactory),
            makeAddr("FEE_1"),
            makeAddr("FEE_2"),
            owner,
            address(withdrawalModule),
            0
        );
        withdrawalModule.setSTEX(address(stex));
        pool = ISovereignPool(stex.pool());

        vm.startPrank(owner);
        swapFeeModule.setPool(address(pool));
        uint32[] memory feeSteps = new uint32[](1);
        feeSteps[0] = 1;
        swapFeeModule.setFeeParamsToken0(15 ether, 30 ether, feeSteps);
        vm.stopPrank();

        aliceShares = _deposit(alice, 1000 ether);
        bobShares = _deposit(bob, 1000 ether);

        // Trader sells 500 stHYPE into the pool so it holds token0
        vm.deal(trader, 500 ether);
        vm.startPrank(trader);
        token0.mint{value: 500 ether}(trader);
        token0.approve(address(pool), 500 ether);
        SovereignPoolSwapParams memory params;
        params.isZeroToOne = true;
        params.amountIn = 500 ether;
        params.deadline = block.timestamp;
        params.swapTokenOut = address(weth);
        params.recipient = trader;
        pool.swap(params);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(stex), amount);
        shares = stex.deposit(amount, 0, block.timestamp, user);
        vm.stopPrank();
    }

    /// @dev Negative rebase of `bips` on every stHYPE holder.
    function _slash(uint256 bips) internal {
        uint256 backing = address(token0).balance;
        vm.deal(address(token0), backing - (backing * bips) / 10_000);
        (uint256 r0, uint256 r1) = pool.getReserves();
        console.log("  -- slashed bips:", bips);
        console.log("     pool reserve0 / reserve1:", r0, r1);
        console.log("     pending LP withdrawal:   ", withdrawalModule.amountToken1PendingLPWithdrawal());
    }

    function _deductionFor(uint256 shares) internal view returns (uint256) {
        (uint256 r0,) = pool.getReserves();
        uint256 u = withdrawalModule.amountToken0PendingUnstaking();
        uint256 p = withdrawalModule.amountToken1PendingLPWithdrawal();
        if (r0 + u > p) return 0;
        return ((p - r0 - u) * shares + stex.totalSupply() - 1) / stex.totalSupply();
    }

    function _withdraw(address user, uint256 shares, string memory label) internal returns (uint256 a0, uint256 a1) {
        uint256 deduction = _deductionFor(shares);
        vm.prank(user);
        (a0, a1) = stex.withdraw(shares, 0, 0, block.timestamp, user, false, false);
        console.log(label);
        console.log("     amount0 (queued, owed 1:1 in HYPE):", a0);
        console.log("     amount1 (token1 paid now):         ", a1);
        console.log("     amount0Deduction:                  ", deduction);
        console.log("     total value:                       ", a0 + a1);
    }

    /// Scenario A (the requested one): slashing happens BEFORE anyone withdraws.
    function test_A_slashBeforeWithdrawals() public {
        console.log("Scenario A: 10% slash before both withdrawals");
        _slash(1000);
        (uint256 a0, uint256 a1) = _withdraw(alice, aliceShares, "  Alice:");
        (uint256 b0, uint256 b1) = _withdraw(bob, bobShares, "  Bob:");

        // Both see the same post-slash reserves -> identical pro-rata payout
        assertApproxEqAbs(a0, b0, 1e6, "token0 differs");
        assertApproxEqAbs(a1, b1, 1e6, "token1 differs");
    }

    /// Scenario B: slashing happens AFTER Alice's withdrawal is queued, before Bob withdraws.
    function test_B_slashBetweenWithdrawals() public {
        console.log("Scenario B: 10% slash after Alice queued, before Bob");
        (uint256 a0, uint256 a1) = _withdraw(alice, aliceShares, "  Alice:");
        _slash(1000);
        (uint256 b0, uint256 b1) = _withdraw(bob, bobShares, "  Bob:");

        uint256 aliceValue = a0 + a1;
        uint256 bobValue = b0 + b1;
        console.log("  Bob shortfall vs Alice:", aliceValue - bobValue);

        // Pool lost 10% of 500 = 50 token0. Fair split would be ~25 each.
        // Alice's queued claim is fixed in HYPE, so Bob absorbs the whole 50.
        assertApproxEqAbs(aliceValue - bobValue, 50 ether, 1e6);
        assertApproxEqAbs(b1, a1, 1e6, "Bob's token1 is not slashed in the 10% case");
    }

    /// Scenario C: slash large enough that reserve0 < pending queue -> else branch.
    function test_C_largeSlashHitsDeductionBranch() public {
        console.log("Scenario C: 60% slash after Alice queued, before Bob");
        (uint256 a0, uint256 a1) = _withdraw(alice, aliceShares, "  Alice:");
        _slash(6000);
        (uint256 b0, uint256 b1) = _withdraw(bob, bobShares, "  Bob:");

        // Pool keeps enough to honor Alice's queue: reserve0 + leftover token1 >= queue
        (uint256 r0, uint256 r1) = pool.getReserves();
        console.log("  pool after Bob: reserve0 / reserve1:", r0, r1);
        console.log("  queue owed to Alice:", withdrawalModule.amountToken1PendingLPWithdrawal());
        assertEq(b0, 0);
        assertLt(b1, a1);
        assertGe(r0 + r1 + 1e6, withdrawalModule.amountToken1PendingLPWithdrawal());
    }
}
