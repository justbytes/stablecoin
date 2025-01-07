// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Importing libraries
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DecentralizedStableCoin
/// @author justbytes
/// @dev Collateral: Exogenous (ETH & BTC)
/// @dev Minting: Algorithmic
/// @dev Relative Stability: Pegged to USD
/// @notice This is the contract that is to be governed by the DSLEngine
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    // Errors
    error DecentralizedStableCoin__InsufficientBalance();
    error DecentralizedStableCoin__InsufficientAmount();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__CannotMintToZeroAddress();

    // State variables
    address private immutable i_owner;

    // Constructor
    constructor() ERC20("DefiStable", "DSL") Ownable(msg.sender) {
        i_owner = msg.sender;
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (balance <= 0) {
            revert DecentralizedStableCoin__InsufficientBalance();
        } else if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__CannotMintToZeroAddress();
        } else if (_amount <= 0) {
            revert DecentralizedStableCoin__InsufficientAmount();
        }

        _mint(_to, _amount);
        return true;
    }
}
