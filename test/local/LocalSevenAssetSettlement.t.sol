// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SevenAssetSettlementChecks} from '../integration/SevenAssetCoWSettlement.t.sol';
import {GPv2AllowListAuthentication} from '@cowprotocol/GPv2AllowListAuthentication.sol';
import {GPv2Settlement} from '@cowprotocol/GPv2Settlement.sol';
import {IVault} from '@cowprotocol/interfaces/IVault.sol';
import {ISettlement} from 'interfaces/ISettlement.sol';

/// @notice Deploys the actual pinned CoW contracts without a fork or mocked authentication.
contract LocalSevenAssetCoWSettlementTest is SevenAssetSettlementChecks {
  GPv2AllowListAuthentication internal authentication;

  function setUp() public {
    authentication = new GPv2AllowListAuthentication();
    authentication.initializeManager(address(this));
    address localSolver = vm.addr(0x51501);
    authentication.addSolver(localSolver);
    // ERC20 balance markers transfer directly through the real vault relayer.
    // Balancer Vault internal balances and batchSwap are outside this fixture.
    GPv2Settlement localSettlement = new GPv2Settlement(authentication, IVault(address(0)));
    _setUpPool(ISettlement(address(localSettlement)), localSolver);
  }

  function test_OnlyManagerCanRegisterSolver() public {
    address unauthorized = makeAddr('unauthorized');
    vm.expectRevert(bytes('GPv2: caller not manager'));
    vm.prank(unauthorized);
    authentication.addSolver(unauthorized);
  }
}
