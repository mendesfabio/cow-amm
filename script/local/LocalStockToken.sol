// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @notice Unrestricted minting for the local M7 demonstration only.
contract LocalStockToken is ERC20 {
  uint8 internal immutable _DECIMALS;

  constructor(
    // solhint-disable-next-line no-unused-vars
    string memory name_,
    // solhint-disable-next-line no-unused-vars
    string memory symbol_,
    uint8 decimals_
  ) ERC20(name_, symbol_) {
    _DECIMALS = decimals_;
  }

  function mint(
    address recipient,
    uint256 amount
  ) external {
    _mint(recipient, amount);
  }

  function decimals() public view override returns (uint8) {
    return _DECIMALS;
  }
}
