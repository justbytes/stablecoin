// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;
    address public user = makeAddr("user");

    function setUp() public {
        dsc = new DecentralizedStableCoin();
    }

    //////////////////
    // Mint Tests ////
    //////////////////

    function testMintSuccessfully() public {
        uint256 amount = 100;
        bool success = dsc.mint(user, amount);

        assertEq(success, true);
        assertEq(dsc.balanceOf(user), amount);
    }

    function testCannotMintToZeroAddress() public {
        uint256 amount = 100;

        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__CannotMintToZeroAddress.selector);
        dsc.mint(address(0), amount);
    }

    function testCannotMintZeroAmount() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__InsufficientAmount.selector);
        dsc.mint(user, 0);
    }

    function testOnlyOwnerCanMint() public {
        vm.prank(user);
        vm.expectRevert();
        dsc.mint(user, 100);
    }

    //////////////////
    // Burn Tests ////
    //////////////////

    function testBurnSuccessfully() public {
        uint256 amountToMint = 100;
        uint256 amountToBurn = 50;

        dsc.mint(address(this), amountToMint);
        dsc.burn(amountToBurn);

        assertEq(dsc.balanceOf(address(this)), amountToMint - amountToBurn);
    }

    function testCannotBurnWithZeroBalance() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__InsufficientBalance.selector);
        dsc.burn(100);
    }

    function testCannotBurnMoreThanBalance() public {
        uint256 amountToMint = 50;
        uint256 amountToBurn = 100;

        dsc.mint(address(this), amountToMint);

        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(amountToBurn);
    }

    function testOnlyOwnerCanBurn() public {
        dsc.mint(user, 100);

        vm.prank(user);
        vm.expectRevert();
        dsc.burn(50);
    }
}
