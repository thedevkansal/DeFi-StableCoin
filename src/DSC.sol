//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DSC__Burn_amount_less_than_zero();
    error DSC__Burn_amount_exceeds_balance();
    error DSC__Not_Zero_Adress();
    error DSC__Amount_less_than_zero();

    constructor() ERC20("Decentralized Stable Coin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DSC__Burn_amount_less_than_zero();
        }
        if (balance < _amount) {
            revert DSC__Burn_amount_exceeds_balance();
        }
        super.burn(_amount); // Calls the burn function from ERC20Burnable.sol
    }

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool success) {
        if (_to == address(0)) {
            revert DSC__Not_Zero_Adress();
        }
        if (_amount <= 0) {
            revert DSC__Amount_less_than_zero();
        }
        _mint(_to, _amount); // Calls the mint function from ERC20.sol
        return true;
    }
}
