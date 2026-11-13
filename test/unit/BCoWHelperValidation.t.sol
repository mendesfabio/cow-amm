// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ICOWAMMPoolHelper} from '@cow-amm/interfaces/ICOWAMMPoolHelper.sol';
import {GPv2Interaction} from '@cowprotocol/libraries/GPv2Interaction.sol';
import {GPv2Order} from '@cowprotocol/libraries/GPv2Order.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {BCoWFactory} from 'contracts/BCoWFactory.sol';
import {BCoWHelper} from 'contracts/BCoWHelper.sol';
import {BCoWPool} from 'contracts/BCoWPool.sol';
import {Test} from 'forge-std/Test.sol';
import {IBPool} from 'interfaces/IBPool.sol';
import {ISettlement} from 'interfaces/ISettlement.sol';

contract HelperValidationToken is ERC20 {
  constructor() ERC20('Validation token', 'TEST') {}

  function mint(
    address recipient,
    uint256 amount
  ) external {
    _mint(recipient, amount);
  }
}

/// @notice PR review checks using actual pools and ERC20 balances, without a fork.
contract BCoWHelperValidationTest is Test {
  BCoWFactory internal factory;
  BCoWHelper internal helper;
  address internal settlement;

  function setUp() public {
    settlement = makeAddr('settlement');
    vm.mockCall(settlement, abi.encodeCall(ISettlement.domainSeparator, ()), abi.encode(bytes32('domain')));
    vm.mockCall(settlement, abi.encodeCall(ISettlement.vaultRelayer, ()), abi.encode(makeAddr('relayer')));
    factory = new BCoWFactory(settlement, bytes32('appData'), address(this));
    helper = new BCoWHelper(address(factory));
  }

  function _pool(
    uint256[] memory weights,
    uint256[] memory balances
  ) internal returns (BCoWPool pool) {
    IBPool created = factory.newBPool('Portfolio', 'PORT');
    for (uint256 i; i < weights.length; ++i) {
      HelperValidationToken token = new HelperValidationToken();
      token.mint(address(this), balances[i]);
      token.approve(address(created), balances[i]);
      created.bind(address(token), balances[i], weights[i]);
    }
    // Deployed CoW pools deter the ordinary swap path with a high fee.
    created.setSwapFee(1e18 - 1e12);
    created.finalize();
    pool = BCoWPool(address(created));
  }

  function _m7() internal returns (BCoWPool pool) {
    uint256[] memory weights = new uint256[](7);
    uint256[] memory balances = new uint256[](7);
    weights[0] = 8e18;
    for (uint256 i = 1; i < 5; ++i) {
      weights[i] = 6e18;
    }
    weights[5] = 4e18;
    weights[6] = 4e18;
    for (uint256 i; i < 7; ++i) {
      balances[i] = weights[i] * 100;
    }
    pool = _pool(weights, balances);
  }

  function _prices(
    uint256 count
  ) internal pure returns (uint256[] memory prices) {
    prices = new uint256[](count);
    for (uint256 i; i < count; ++i) {
      prices[i] = 1e18;
    }
  }

  function test_M7AtEquilibriumHasNoOrder() public {
    BCoWPool pool = _m7();
    uint256[] memory prices = _prices(7);
    assertEq(helper.tokens(address(pool)).length, 7);
    vm.expectRevert(ICOWAMMPoolHelper.NoOrder.selector);
    helper.order(address(pool), prices);
  }

  function test_M7PriceMoveProducesValidOrderAndCommitment() public {
    BCoWPool pool = _m7();
    uint256[] memory prices = _prices(7);
    prices[0] = 1.1e18;
    uint256 gasBefore = gasleft();
    (GPv2Order.Data memory order, GPv2Interaction.Data[] memory pre,, bytes memory sig) =
      helper.order(address(pool), prices);
    emit log_named_uint('Seven-token helper gas (warm setup)', gasBefore - gasleft());
    address[] memory tokens = helper.tokens(address(pool));
    assertEq(address(order.sellToken), tokens[0]);
    assertGt(order.sellAmount, 0);
    assertGt(order.buyAmount, 0);
    pool.verify(order);
    assertEq(pre.length, 1);
    assertEq(pre[0].target, address(pool));
    assertEq(sig.length, 20 + abi.encode(order).length);
    vm.prank(settlement);
    (bool success,) = pre[0].target.call(pre[0].callData);
    assertTrue(success);
    bytes32 orderHash = GPv2Order.hash(order, pool.SOLUTION_SETTLER_DOMAIN_SEPARATOR());
    assertEq(pool.isValidSignature(orderHash, abi.encode(order)), bytes4(0x1626ba7e));
  }

  function test_MixedRawTokenUnitsProduceValidOrder() public {
    uint256[] memory weights = new uint256[](3);
    uint256[] memory balances = new uint256[](3);
    for (uint256 i; i < 3; ++i) {
      weights[i] = 1e18;
    }
    // Equivalent to 18-, 6-, and 8-decimal assets. The helper reads raw units,
    // not decimals(), so decimals metadata does not participate in this check.
    balances[0] = 100e18;
    balances[1] = 100e6;
    balances[2] = 100e8;
    BCoWPool pool = _pool(weights, balances);
    uint256[] memory prices = new uint256[](3);
    prices[0] = 1;
    prices[1] = 1e12;
    prices[2] = 1e10;
    vm.expectRevert(ICOWAMMPoolHelper.NoOrder.selector);
    helper.order(address(pool), prices);
    prices[1] = 11e11;
    (GPv2Order.Data memory order,,,) = helper.order(address(pool), prices);
    assertEq(address(order.sellToken), helper.tokens(address(pool))[1]);
    pool.verify(order);
  }

  function test_CommonPriceScaleDoesNotChangeOrder() public {
    BCoWPool pool = _m7();
    uint256[] memory prices = new uint256[](7);
    for (uint256 i; i < 7; ++i) {
      prices[i] = 100;
    }
    prices[0] = 110;
    (GPv2Order.Data memory original,,,) = helper.order(address(pool), prices);
    for (uint256 i; i < 7; ++i) {
      prices[i] *= 1e18;
    }
    (GPv2Order.Data memory scaled,,,) = helper.order(address(pool), prices);
    assertEq(keccak256(abi.encode(original)), keccak256(abi.encode(scaled)));
  }

  function test_M7MixedRawTokenUnitsProduceValidOrder() public {
    uint256[] memory weights = new uint256[](7);
    uint256[] memory balances = new uint256[](7);
    uint256[] memory prices = _prices(7);
    weights[0] = 8e18;
    for (uint256 i = 1; i < 5; ++i) {
      weights[i] = 6e18;
    }
    weights[5] = 4e18;
    weights[6] = 4e18;
    for (uint256 i; i < 7; ++i) {
      balances[i] = weights[i] * 100;
    }
    balances[1] /= 1e12;
    prices[1] *= 1e12;
    balances[2] /= 1e10;
    prices[2] *= 1e10;
    BCoWPool pool = _pool(weights, balances);
    vm.expectRevert(ICOWAMMPoolHelper.NoOrder.selector);
    helper.order(address(pool), prices);
    prices[6] = 1.1e18;
    (GPv2Order.Data memory order,,,) = helper.order(address(pool), prices);
    assertEq(address(order.sellToken), helper.tokens(address(pool))[6]);
    pool.verify(order);
  }

  function testFuzz_M7ModeratePriceMovesProduceValidOrder(
    uint256 index,
    uint256 priceBps
  ) public {
    index = bound(index, 0, 6);
    priceBps = bound(priceBps, 5000, 15_000);
    vm.assume(priceBps != 10_000);
    BCoWPool pool = _m7();
    uint256[] memory prices = _prices(7);
    prices[index] = priceBps * 1e14;
    (GPv2Order.Data memory order,,,) = helper.order(address(pool), prices);
    pool.verify(order);
    assertGt(order.sellAmount, 0);
    assertLe(order.buyAmount, order.buyToken.balanceOf(address(pool)) / 2);
  }

  function testFuzz_M7AllConstituentsMove(
    uint256 seed
  ) public {
    BCoWPool pool = _m7();
    address[] memory tokens = helper.tokens(address(pool));
    uint256[] memory prices = new uint256[](7);
    for (uint256 i; i < 7; ++i) {
      prices[i] = (5000 + uint256(keccak256(abi.encode(seed, i))) % 10_001) * 1e14;
    }
    (GPv2Order.Data memory order,,,) = helper.order(address(pool), prices);
    pool.verify(order);
    uint256 sellPrice;
    uint256 buyPrice;
    for (uint256 i; i < 7; ++i) {
      if (tokens[i] == address(order.sellToken)) sellPrice = prices[i];
      if (tokens[i] == address(order.buyToken)) buyPrice = prices[i];
    }
    assertGt(order.sellAmount, 0);
    assertGt(order.buyAmount, 0);
    assertGt(order.sellAmount * sellPrice, order.buyAmount * buyPrice);
    assertLe(order.buyAmount, order.buyToken.balanceOf(address(pool)) / 2);
  }

  function test_LargePriceMoveReturnsBoundedOrder() public {
    BCoWPool pool = _m7();
    uint256[] memory prices = _prices(7);
    prices[5] = 5e18;
    (GPv2Order.Data memory order,,,) = helper.order(address(pool), prices);
    pool.verify(order);
    assertEq(address(order.sellToken), helper.tokens(address(pool))[5]);
    _assertBoundedOrder(pool, order);
  }

  function test_PairSearchHandlesImbalancedPair() public {
    uint256[] memory weights = new uint256[](3);
    uint256[] memory balances = new uint256[](3);
    weights[0] = 1e18;
    weights[1] = 8e18;
    weights[2] = 8e18;
    for (uint256 i; i < 3; ++i) {
      balances[i] = 100e18;
    }
    BCoWPool pool = _pool(weights, balances);
    uint256[] memory prices = _prices(3);
    prices[0] = 100e18;
    prices[2] = 1.1e18;
    (GPv2Order.Data memory order,,,) = helper.order(address(pool), prices);
    pool.verify(order);
    _assertBoundedOrder(pool, order);
  }

  function testFuzz_M7LargePriceMovesStayWithinQuoteLimits(
    uint256 seed
  ) public {
    BCoWPool pool = _m7();
    uint256[] memory prices = new uint256[](7);
    for (uint256 i; i < 7; ++i) {
      prices[i] = (100 + uint256(keccak256(abi.encode(seed, i))) % 999_901) * 1e14;
    }
    (GPv2Order.Data memory order,,,) = helper.order(address(pool), prices);
    pool.verify(order);
    _assertBoundedOrder(pool, order);
  }

  function _assertBoundedOrder(
    BCoWPool pool,
    GPv2Order.Data memory order
  ) internal view {
    uint256 outgoingBalance = order.sellToken.balanceOf(address(pool));
    assertGt(order.sellAmount, 0);
    assertGt(order.buyAmount, 0);
    assertLe(order.buyAmount, order.buyToken.balanceOf(address(pool)) / 2);
    // The canonical order recomputes output with Balancer's approximate
    // forward power math after the inverse quote; allow its rounding error.
    assertLe(order.sellAmount, outgoingBalance / 3 + outgoingBalance / 1e8);
  }
}
