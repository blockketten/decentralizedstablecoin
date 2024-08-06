//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/** @title DecentralizedStableCoin
 * This contract is a decentralized stable coin that is pegged to the US dollar.
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Pegged to USD
 * This contract is simply the ERC20 token contract for the stablecoin, which will be governed by the DSCEngine contract
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountToBeBurnedMustBeGreaterThanZero();
    error DecentralizedStableCoin__AmountToBeBurnedExceedsBalance();
    error DecentralizedStableCoin__CannotMintToZeroAddress();
    error DecentralizedStableCoin__AmountToBeMintedMustBeGreaterThanZero();

    constructor()
        ERC20("DecentralizedStableCoin", "DSC")
        Ownable(address(msg.sender))
    {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountToBeBurnedMustBeGreaterThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__AmountToBeBurnedExceedsBalance();
        }
        super.burn(_amount); //have to use super to override the burn function from ERC20Burnable
    }

    function mint(
        address _to,
        uint256 _amount
    ) public onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__CannotMintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountToBeMintedMustBeGreaterThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
