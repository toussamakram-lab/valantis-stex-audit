// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {SwapFeeModuleData} from "@valantis-core/swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

import {STEXAMM} from "src/STEXAMM.sol";
import {StepwiseFeeModule} from "src/swap-fee-modules/StepwiseFeeModule.sol";
import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {MockOverseer} from "src/mocks/sthype/MockOverseer.sol";
import {MockStHype} from "src/mocks/sthype/MockStHype.sol";

/// @dev Same minimal deployment as Amount0Deduction.t.sol.
contract FeeBypassTest is Test {
    uint256 constant BIPS = 10_000;

    STEXAMM stex;
    StepwiseFeeModule swapFeeModule;
    stHYPEWithdrawalModule withdrawalModule;
    ISovereignPool pool;
    WETH weth;
    MockStHype token0;
    MockOverseer overseer;

    address owner = makeAddr("OWNER");
    address lp = makeAddr("LP");
    address attacker = makeAddr("ATTACKER");

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

        // Same fee curve as stHYPESTEXAMM.t.sol::_setSwapFeeParams(1, 30):
        // 1 bip when reserve1 after swap > 30 ether, stepping up to 30 bips below 15 ether.
        vm.startPrank(owner);
        swapFeeModule.setPool(address(pool));
        uint32[] memory feeSteps = new uint32[](5);
        feeSteps[0] = 1;
        feeSteps[1] = 8;
        feeSteps[2] = 15;
        feeSteps[3] = 22;
        feeSteps[4] = 30;
        swapFeeModule.setFeeParamsToken0(15 ether, 30 ether, feeSteps);
        vm.stopPrank();

        // LP provides 25 ether token1 -> after a 10 ether swap, reserve1 ~15 -> max fee tier
        vm.deal(lp, 25 ether);
        vm.startPrank(lp);
        weth.deposit{value: 25 ether}();
        weth.approve(address(stex), type(uint256).max);
        stex.deposit(25 ether, 0, block.timestamp, lp);
        vm.stopPrank();

        // Seed reserve0 as well so both reserves are non-zero
        _mintToken0(address(this), 5 ether);
        token0.transfer(address(pool), 5 ether);
    }

    function _mintToken0(address to, uint256 amount) internal {
        vm.deal(address(this), amount);
        token0.mint{value: amount}(to);
    }

    function _swap0to1(address user, uint256 amountIn)
        internal
        returns (uint256 amountInUsed, uint256 amountOut, uint256 feeBips)
    {
        SwapFeeModuleData memory fee =
            swapFeeModule.getSwapFeeInBips(address(token0), address(0), amountIn, address(0), new bytes(0));
        feeBips = fee.feeInBips;

        vm.startPrank(user);
        token0.approve(address(pool), amountIn);
        SovereignPoolSwapParams memory params;
        params.isZeroToOne = true;
        params.amountIn = amountIn;
        params.deadline = block.timestamp;
        params.swapTokenOut = address(weth);
        params.recipient = user;
        (amountInUsed, amountOut) = pool.swap(params);
        vm.stopPrank();
    }

    /// Baseline: no donation, swap lands in a high fee tier.
    function test_baseline_noDonation() public {
        uint256 amountIn = 10 ether;
        _mintToken0(attacker, amountIn);

        (uint256 used, uint256 out, uint256 feeBips) = _swap0to1(attacker, amountIn);
        uint256 amountInWithoutFee = Math.mulDiv(amountIn, BIPS, BIPS + feeBips);

        console.log("Baseline fee (pool bips):     ", feeBips);
        console.log("amountIn used:                ", used);
        console.log("amountOut:                    ", out);
        console.log("convertToToken1(inMinusFee):  ", withdrawalModule.convertToToken1(amountInWithoutFee));
        console.log("convertToToken1(amountIn):    ", withdrawalModule.convertToToken1(amountIn));

        assertGt(feeBips, 1);
        assertLe(out, withdrawalModule.convertToToken1(amountInWithoutFee), "output above fair conversion");
    }

    /// Attack: donate token1 to push reserve1 into the minimum fee tier, then swap.
    function test_donationLowersFeeTier() public {
        uint256 amountIn = 10 ether;
        uint256 donation = 100 ether;
        _mintToken0(attacker, amountIn);
        vm.deal(attacker, donation);
        vm.startPrank(attacker);
        weth.deposit{value: donation}();
        weth.transfer(address(pool), donation);
        vm.stopPrank();

        (uint256 used, uint256 out, uint256 feeBips) = _swap0to1(attacker, amountIn);
        uint256 amountInWithoutFee = Math.mulDiv(amountIn, BIPS, BIPS + feeBips);
        uint256 fair = withdrawalModule.convertToToken1(amountInWithoutFee);

        console.log("Fee after donation (pool bips):", feeBips);
        console.log("amountIn used:                 ", used);
        console.log("amountOut:                     ", out);
        console.log("convertToToken1(inMinusFee):   ", fair);
        console.log("convertToToken1(amountIn):     ", withdrawalModule.convertToToken1(amountIn));

        // Fee drops to the minimum step but never to zero
        assertEq(feeBips, 1);
        assertGt(feeBips, 0, "attacker paid zero fee");
        // Output is exactly the quoted conversion, never more
        assertLe(out, fair, "output above convertToToken1(amountInMinusFee)");
        assertLt(out, withdrawalModule.convertToToken1(amountIn), "output >= 1:1 conversion");

        // Economics: donation is gifted to LPs, attacker has no LP shares to recover it
        uint256 baselineOut = withdrawalModule.convertToToken1(Math.mulDiv(amountIn, BIPS, BIPS + 30 * BIPS / (BIPS - 30)));
        console.log("Fee saved vs max tier:         ", out - baselineOut);
        console.log("Donation lost to LPs:          ", donation);
        console.log("LP's share value now:          ", _lpValue());
    }

    /// token1 -> token0 swaps are fee-less by design (fee module returns 0 for tokenIn != token0).
    function test_oneToZero_isDesignedFeeless() public {
        uint256 amountIn = 1 ether;
        vm.deal(attacker, amountIn);
        vm.startPrank(attacker);
        weth.deposit{value: amountIn}();
        weth.approve(address(pool), amountIn);
        SovereignPoolSwapParams memory params;
        params.isZeroToOne = false;
        params.amountIn = amountIn;
        params.deadline = block.timestamp;
        params.swapTokenOut = address(token0);
        params.recipient = attacker;
        (, uint256 out) = pool.swap(params);
        vm.stopPrank();

        console.log("1->0 amountOut:", out);
        console.log("convertToToken0(amountIn):", withdrawalModule.convertToToken0(amountIn));
        assertLe(out, withdrawalModule.convertToToken0(amountIn));
    }

    function _lpValue() internal view returns (uint256) {
        (uint256 r0, uint256 r1) = pool.getReserves();
        return (r0 + r1) * stex.balanceOf(lp) / stex.totalSupply();
    }
}
