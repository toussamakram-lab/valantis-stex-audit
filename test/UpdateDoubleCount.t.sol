// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {stHYPEWithdrawalModule} from "src/withdrawal-modules/stHYPEWithdrawalModule.sol";
import {ISTEXAMM} from "src/interfaces/ISTEXAMM.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";

contract UpdateDoubleCountTest is Test {
    using stdStorage for StdStorage;

    stHYPEWithdrawalModule module;

    address constant STEX = address(0xBEEF);
    address constant POOL = address(0xB001);

    function setUp() public {
        module = new stHYPEWithdrawalModule(address(0xCAFE), address(0xDEAD), address(this));

        // setSTEX() calls ISTEXAMM(stex).pool() and update() calls ISovereignPool(pool).isLocked(),
        // so both dummy addresses need code + mocked return values or the calls revert.
        vm.etch(STEX, hex"00");
        vm.etch(POOL, hex"00");
        vm.mockCall(STEX, abi.encodeWithSelector(ISTEXAMM.pool.selector), abi.encode(POOL));
        vm.mockCall(POOL, abi.encodeWithSelector(ISovereignPool.isLocked.selector), abi.encode(false));

        module.setSTEX(STEX);
    }

    function test_updateDoubleCount() public {
        stdstore.target(address(module)).sig(module.amountToken0PendingUnstakingBeforeUpdate.selector)
            .checked_write(uint256(100 ether));
        stdstore.target(address(module)).sig(module.amountToken1PendingLPWithdrawalBeforeUpdate.selector)
            .checked_write(uint256(100 ether));

        vm.deal(address(this), 30 ether);
        (bool ok,) = address(module).call{value: 30 ether}("");
        assertTrue(ok);

        module.update();

        uint256 u_after = module.amountToken0PendingUnstakingBeforeUpdate();
        uint256 p_after = module.amountToken1PendingLPWithdrawalBeforeUpdate();

        assertEq(u_after, 70 ether);
        assertEq(p_after, 70 ether);

        console.log("Total drop:", (100 ether - u_after) + (100 ether - p_after));

        // Solvency check: is any native value actually created?
        console.log("Native balance of module:     ", address(module).balance);
        console.log("amountToken1ClaimableLPWithdrawal:", module.amountToken1ClaimableLPWithdrawal());
        assertEq(module.amountToken1ClaimableLPWithdrawal(), address(module).balance);
    }
}
