// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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

/// @dev Minimal deployment: the setUp in stHYPESTEXAMM.t.sol reverts on current Forge
///      (vm.expectRevert around `new DepositWrapper(...)` at the cheatcode depth).
contract Amount0DeductionTest is Test {
    STEXAMM stex;
    StepwiseFeeModule swapFeeModule;
    stHYPEWithdrawalModule withdrawalModule;
    ISovereignPool pool;
    WETH weth;
    MockStHype token0;
    MockOverseer overseer;

    address owner = makeAddr("OWNER");
    address attacker = makeAddr("ATTACKER");
    address victim = makeAddr("VICTIM");
    address trader = makeAddr("TRADER");

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
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(stex), amount);
        shares = stex.deposit(amount, 0, block.timestamp, user);
        vm.stopPrank();
    }

    /// @dev Replicates the amount0Deduction branch of STEXAMM.withdraw() from current state.
    function _amount0Deduction(uint256 shares) internal view returns (uint256) {
        (uint256 r0,) = pool.getReserves();
        uint256 u = withdrawalModule.amountToken0PendingUnstaking();
        uint256 p = withdrawalModule.amountToken1PendingLPWithdrawal();
        if (r0 + u > p) return 0;
        return ((p - r0 - u) * shares + stex.totalSupply() - 1) / stex.totalSupply();
    }

    function _withdraw(address user, uint256 shares, string memory label)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 deduction = _amount0Deduction(shares);
        vm.prank(user);
        (amount0, amount1) = stex.withdraw(shares, 0, 0, block.timestamp, user, false, false);

        console.log(label);
        console.log("  amount0 (queued token0):", amount0);
        console.log("  amount1 (token1 paid):  ", amount1);
        console.log("  amount0Deduction:       ", deduction);
        console.log("  pending LP withdrawal:  ", withdrawalModule.amountToken1PendingLPWithdrawal());
        (uint256 r0, uint256 r1) = pool.getReserves();
        console.log("  pool reserve0 / reserve1:", r0, r1);
    }

    /// Attack exactly as described: pool only ever received token1 deposits.
    function test_attack_token1OnlyPool() public {
        uint256 attackerShares = _deposit(attacker, 1000 ether);
        uint256 victimShares = _deposit(victim, 1000 ether);

        (uint256 a0, uint256 a1) = _withdraw(attacker, attackerShares, "Attacker:");
        (uint256 v0, uint256 v1) = _withdraw(victim, victimShares, "Victim:");

        // reserve0 == 0, so the attacker's withdrawal can't add anything to the queue.
        assertEq(a0, 0);
        assertEq(v0, 0);
        assertEq(withdrawalModule.amountToken1PendingLPWithdrawal(), 0);
        assertApproxEqAbs(v1, 1000 ether, 1e6, "victim token1 slashed");
        assertApproxEqAbs(a1, 1000 ether, 1e6);
    }

    /// Stronger variant: the pool holds token0 (from a swap) so the attacker's withdrawal
    /// really does inflate the LP withdrawal queue before the victim withdraws.
    function test_attack_poolHoldsToken0() public {
        uint256 attackerShares = _deposit(attacker, 1000 ether);
        uint256 victimShares = _deposit(victim, 1000 ether);

        // Trader sells 500 stHYPE into the pool
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

        (uint256 r0, uint256 r1) = pool.getReserves();
        console.log("Pool after swap reserve0 / reserve1:", r0, r1);

        (uint256 a0, uint256 a1) = _withdraw(attacker, attackerShares, "Attacker:");

        // Attacker's queued token0 is still sitting in the pool (no unstake yet)
        assertGt(withdrawalModule.amountToken1PendingLPWithdrawal(), 0);

        uint256 victimDeduction = _amount0Deduction(victimShares);
        (uint256 v0, uint256 v1) = _withdraw(victim, victimShares, "Victim:");

        // Victim never hits the else branch and gets the same pro-rata payout as the attacker
        assertEq(victimDeduction, 0, "victim hit amount0Deduction branch");
        assertApproxEqAbs(v0, a0, 1e6, "victim token0 slashed");
        assertApproxEqAbs(v1, a1, 1e6, "victim token1 slashed");

        // Queue is fully backed by token0 still in the pool
        (r0,) = pool.getReserves();
        assertGe(r0 + 1e6, withdrawalModule.amountToken1PendingLPWithdrawal());
    }
}
