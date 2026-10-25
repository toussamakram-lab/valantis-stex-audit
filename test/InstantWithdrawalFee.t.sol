// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ProtocolFactory} from "@valantis-core/protocol-factory/ProtocolFactory.sol";
import {SovereignPoolFactory} from "@valantis-core/pools/factories/SovereignPoolFactory.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {SovereignPoolSwapParams} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {SwapFeeModuleData} from "@valantis-core/swap-fee-modules/interfaces/ISwapFeeModule.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

import {STEXAMM} from "src/STEXAMM.sol";
import {StepwiseFeeModule} from "src/swap-fee-modules/StepwiseFeeModule.sol";
import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {MockOverseer} from "src/mocks/sthype/MockOverseer.sol";
import {MockStHype} from "src/mocks/sthype/MockStHype.sol";

/// @dev Same minimal deployment as Amount0Deduction.t.sol.
///      Compares, from an identical pool state:
///        A) standard withdraw + selling the same amount0 of stHYPE through pool.swap (full StepwiseFee)
///        B) instant withdraw (fee module is queried with _amountIn = 0)
contract InstantWithdrawalFeeTest is Test {
    STEXAMM stex;
    StepwiseFeeModule swapFeeModule;
    stHYPEWithdrawalModule withdrawalModule;
    ISovereignPool pool;
    WETH weth;
    MockStHype token0;
    MockOverseer overseer;

    address owner = makeAddr("OWNER");
    address lpA = makeAddr("LP_A");
    address lpB = makeAddr("LP_B");
    address trader = makeAddr("TRADER");

    uint256 sharesA;
    uint256 sharesB;

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

        // Fee curve: 1 bip above 30 ether token1 left after swap, up to 30 bips at/below 15 ether.
        vm.startPrank(owner);
        swapFeeModule.setPool(address(pool));
        uint32[] memory feeSteps = new uint32[](5);
        feeSteps[0] = 1;
        feeSteps[1] = 8;
        feeSteps[2] = 15;
        feeSteps[3] = 22;
        feeSteps[4] = 30;
        swapFeeModule.setFeeParamsToken0(15 ether, 30 ether, feeSteps);
        // 10% of swap fees to the pool manager, so instantWithdrawalFee1 is non-zero
        stex.setPoolManagerFeeBips(1_000);
        vm.stopPrank();

        sharesA = _deposit(lpA, 25 ether);
        sharesB = _deposit(lpB, 25 ether);

        // Trader sells 20 stHYPE -> pool holds ~20 token0 / ~30 token1
        _mintToken0(trader, 20 ether);
        _swap0to1(trader, 20 ether);

        (uint256 r0, uint256 r1) = pool.getReserves();
        console.log("Pool reserve0 / reserve1:", r0, r1);
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(stex), amount);
        shares = stex.deposit(amount, 0, block.timestamp, user);
        vm.stopPrank();
    }

    function _mintToken0(address to, uint256 amount) internal {
        vm.deal(address(this), amount);
        token0.mint{value: amount}(to);
    }

    function _swap0to1(address user, uint256 amountIn) internal returns (uint256 amountOut) {
        vm.startPrank(user);
        token0.approve(address(pool), amountIn);
        SovereignPoolSwapParams memory params;
        params.isZeroToOne = true;
        params.amountIn = amountIn;
        params.deadline = block.timestamp;
        params.swapTokenOut = address(weth);
        params.recipient = user;
        (, amountOut) = pool.swap(params);
        vm.stopPrank();
    }

    function _feeBips(uint256 amountIn) internal view returns (uint256) {
        SwapFeeModuleData memory d =
            swapFeeModule.getSwapFeeInBips(address(token0), address(0), amountIn, address(0), new bytes(0));
        return d.feeInBips;
    }

    function test_instantWithdrawalVsSwap() public {
        uint256 snap = vm.snapshotState();

        // ---- Path A: standard withdraw, then sell amount0 via pool.swap ----
        vm.prank(lpA);
        (uint256 a0, uint256 a1) = stex.withdraw(sharesA, 0, 0, block.timestamp, lpA, false, false);
        // amount0 is a queued 1:1 HYPE claim, not stHYPE in hand. To price "selling amount0 through the
        // pool" we swap the same amount of stHYPE, from the same pool state (token0 is still in the pool).
        uint256 swapFeeA = _feeBips(a0);
        _mintToken0(lpA, a0);
        uint256 swapOutA = _swap0to1(lpA, a0);
        uint256 totalA = a1 + swapOutA;

        vm.revertToState(snap);

        // ---- Path B: instant withdrawal ----
        uint256 feeInstant = _feeBips(0);
        uint256 stexWethBefore = weth.balanceOf(address(stex));
        vm.prank(lpB);
        (uint256 b0, uint256 totalB) = stex.withdraw(sharesB, 0, 0, block.timestamp, lpB, false, true);
        uint256 instantWithdrawalFee1 = weth.balanceOf(address(stex)) - stexWethBefore;

        uint256 fair = a1 + withdrawalModule.convertToToken1(a0);

        console.log("amount0 (pro-rata token0):         ", a0);
        console.log("amount1 (pro-rata token1):         ", a1);
        console.log("Fair value a1 + convert(a0):       ", fair);
        console.log("--- Path A: withdraw + swap ---");
        console.log("  swap fee (pool bips):            ", swapFeeA);
        console.log("  swap output for amount0:         ", swapOutA);
        console.log("  total token1:                    ", totalA);
        console.log("--- Path B: instant withdrawal ---");
        console.log("  fee (pool bips, amountIn = 0):   ", feeInstant);
        console.log("  amount0 returned:                ", b0);
        console.log("  total token1:                    ", totalB);
        console.log("  instantWithdrawalFee1 (manager): ", instantWithdrawalFee1);
        console.log("--- Comparison ---");
        console.log("  B advantage over A:              ", totalB - totalA);
        console.log("  B shortfall vs fair value:       ", fair - totalB);
        console.log("  B advantage, bips of amount0:    ", (totalB - totalA) * 10_000 / a0);

        assertEq(b0, 0);
        // Never more than the fair conversion
        assertLe(totalB, fair, "instant withdrawal paid above convertToToken1(amount0)");
        // Fee is reduced, not removed
        assertGt(feeInstant, 0, "instant withdrawal paid zero fee");
        assertLt(feeInstant, swapFeeA);
        assertGt(totalB, totalA);
    }
}
