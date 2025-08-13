//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DSC__NeedsMoreThanZero();
    error DSC__BurnAmountExceedsBalance();
    error DSC__AddressNotAllowed();

    constructor() ERC20("Decentralized Stable Coin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DSC__NeedsMoreThanZero();
        }
        if (balance < _amount) {
            revert DSC__BurnAmountExceedsBalance();
        }
        super.burn(_amount); // Calls the burn function from ERC20Burnable.sol
    }

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool success) {
        if (_to == address(0)) {
            revert DSC__AddressNotAllowed();
        }
        if (_amount <= 0) {
            revert DSC__NeedsMoreThanZero();
        }
        _mint(_to, _amount); // Calls the mint function from ERC20.sol
        return true;
    }
}
