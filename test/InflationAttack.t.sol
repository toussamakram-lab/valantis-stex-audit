// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

import {STEXAMM} from "src/STEXAMM.sol";
import {StepwiseFeeModule} from "src/swap-fee-modules/StepwiseFeeModule.sol";
import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {MockOverseer} from "src/mocks/sthype/MockOverseer.sol";
import {MockStHype} from "src/mocks/sthype/MockStHype.sol";

/// @dev Same minimal deployment as Amount0Deduction.t.sol.
contract InflationAttackTest is Test {
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

        vm.prank(owner);
        swapFeeModule.setPool(address(pool));
    }

    function _fund(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(stex), type(uint256).max);
        vm.stopPrank();
    }

    function test_inflationAttack() public {
        uint256 donation = 10_000 ether;
        uint256 victimDeposit = 1_999 ether;
        _fund(attacker, 1001 + donation);
        _fund(victim, victimDeposit);

        // 1. Attacker is first depositor
        vm.prank(attacker);
        uint256 attackerShares = stex.deposit(1001, 0, block.timestamp, attacker);
        console.log("Attacker shares:        ", attackerShares);
        console.log("Dead shares (address 1):", stex.balanceOf(address(1)));

        // 2. Attacker donates token1 directly to the pool
        vm.prank(attacker);
        weth.transfer(address(pool), donation);
        (, uint256 r1) = pool.getReserves();
        console.log("Pool reserve1 after donation:", r1);

        // 3. Victim deposits
        vm.prank(victim);
        uint256 victimShares = stex.deposit(victimDeposit, 0, block.timestamp, victim);
        console.log("Victim shares:          ", victimShares);

        // 4. Attacker withdraws
        vm.prank(attacker);
        (, uint256 attackerOut) = stex.withdraw(attackerShares, 0, 0, block.timestamp, attacker, false, false);

        // Victim withdraws too, to measure their real loss
        vm.prank(victim);
        (, uint256 victimOut) = stex.withdraw(victimShares, 0, 0, block.timestamp, victim, false, false);

        uint256 attackerIn = 1001 + donation;
        (, r1) = pool.getReserves();

        console.log("Attacker spent:         ", attackerIn);
        console.log("Attacker withdrew:      ", attackerOut);
        console.log("Attacker net loss:      ", attackerIn - attackerOut);
        console.log("Victim deposited:       ", victimDeposit);
        console.log("Victim withdrew:        ", victimOut);
        console.log("Victim loss (rounding): ", victimDeposit - victimOut);
        console.log("Stuck behind dead shares:", r1);

        assertGt(victimShares, 0, "victim got 0 shares");
        assertLt(attackerOut, attackerIn, "attacker profited");
    }

    /// Donation needed to round the victim to 0 shares: deposit then reverts instead of minting 0.
    function test_inflationAttack_zeroSharesReverts() public {
        uint256 victimDeposit = 1_999 ether;
        // shares = deposit * 1001 / reserve1 == 0  <=>  reserve1 > deposit * 1001
        uint256 donation = victimDeposit * 1001;
        _fund(attacker, 1001 + donation);
        _fund(victim, victimDeposit);

        vm.startPrank(attacker);
        stex.deposit(1001, 0, block.timestamp, attacker);
        weth.transfer(address(pool), donation);
        vm.stopPrank();

        console.log("Donation required to zero victim's shares:", donation);

        vm.prank(victim);
        vm.expectRevert(STEXAMM.STEXAMM__deposit_zeroShares.selector);
        stex.deposit(victimDeposit, 0, block.timestamp, victim);
    }
}
