// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {GPv2TradeEncoder} from '@composable-cow/test/vendored/GPv2TradeEncoder.sol';
import {IERC20} from '@cowprotocol/interfaces/IERC20.sol';
import {GPv2Interaction} from '@cowprotocol/libraries/GPv2Interaction.sol';
import {GPv2Order} from '@cowprotocol/libraries/GPv2Order.sol';
import {GPv2Trade} from '@cowprotocol/libraries/GPv2Trade.sol';
import {GPv2Signing} from '@cowprotocol/mixins/GPv2Signing.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {BCoWFactory} from 'contracts/BCoWFactory.sol';
import {BCoWHelper} from 'contracts/BCoWHelper.sol';
import {BCoWPool} from 'contracts/BCoWPool.sol';
import {Test} from 'forge-std/Test.sol';
import {IBCoWPool} from 'interfaces/IBCoWPool.sol';
import {ISettlement} from 'interfaces/ISettlement.sol';

contract SevenAssetSettlementToken is ERC20 {
  uint8 internal immutable DECIMALS;

  constructor(
    uint8 decimals_
  ) ERC20('Mock stock', 'STOCK') {
    DECIMALS = decimals_;
  }

  function decimals() public view override returns (uint8) {
    return DECIMALS;
  }

  function mint(
    address recipient,
    uint256 amount
  ) external {
    _mint(recipient, amount);
  }
}

/// @notice Tests actual token-moving settlements, not a solver auction or LVR guarantee.
abstract contract SevenAssetSettlementChecks is Test {
  using GPv2Order for GPv2Order.Data;

  ISettlement internal settlement;
  address internal solver;
  uint256 internal constant TRADER_KEY = 0x123456;
  BCoWPool internal pool;
  BCoWHelper internal helper;
  address internal trader;
  IERC20[] internal tokens;
  uint256[] internal weights;
  uint256[] internal prices;
  uint256[] internal balancesBefore;
  uint256 internal supplyBefore;
  uint256 internal lpSharesBefore;

  struct Batch {
    GPv2Order.Data order;
    uint256 sellIndex;
    uint256 buyIndex;
    uint256 received;
    uint256[] clearingPrices;
    GPv2Trade.Data[] trades;
    GPv2Interaction.Data[][3] interactions;
  }

  function _setUpPool(
    ISettlement settlement_,
    address solver_
  ) internal {
    settlement = settlement_;
    solver = solver_;
    trader = vm.addr(TRADER_KEY);
    BCoWFactory factory = new BCoWFactory(address(settlement), bytes32('seven-asset-test'), address(this));
    helper = new BCoWHelper(address(factory));
    pool = BCoWPool(address(factory.newBPool('M7 portfolio', 'M7')));
    uint8[7] memory decimals = [uint8(18), 6, 8, 18, 6, 18, 8];
    uint256[7] memory units = [uint256(8), 6, 6, 6, 6, 4, 4];
    for (uint256 i; i < 7; ++i) {
      SevenAssetSettlementToken token = new SevenAssetSettlementToken(decimals[i]);
      uint256 balance = units[i] * 100 * 10 ** decimals[i];
      token.mint(address(this), balance);
      token.approve(address(pool), balance);
      pool.bind(address(token), balance, units[i] * 1e18);
      tokens.push(IERC20(address(token)));
      weights.push(units[i]);
      prices.push(1e18 * 10 ** (18 - decimals[i]));
      balancesBefore.push(balance);
    }
    pool.setSwapFee(1e18 - 1e12);
    pool.finalize();
    supplyBefore = pool.totalSupply();
    lpSharesBefore = pool.balanceOf(address(this));
  }

  function test_SevenAssetSettlementPreservesSharesAndUntouchedReserves() public {
    prices[0] = prices[0] * 11 / 10;
    _executeAndVerify(true, solver);
  }

  function test_LargePriceMoveSettlesWithBoundedCandidate() public {
    prices[5] *= 5;
    _executeAndVerify(true, solver);
  }

  function test_SettlementRequiresAuthorizedSolver() public {
    prices[0] = prices[0] * 11 / 10;
    _executeAndVerify(true, makeAddr('not-a-solver'));
  }

  function test_SettlementRequiresPoolCommitment() public {
    prices[0] = prices[0] * 11 / 10;
    _executeAndVerify(false, solver);
  }

  function _executeAndVerify(
    bool includeCommitment,
    address sender
  ) internal {
    Batch memory batch = _prepareBatch(includeCommitment);
    uint256 invariantBefore = _pairInvariant(batch.sellIndex, batch.buyIndex);
    if (sender != solver) vm.expectRevert(bytes('GPv2: not a solver'));
    else if (!includeCommitment) vm.expectRevert(IBCoWPool.OrderDoesNotMatchCommitmentHash.selector);
    vm.prank(sender);
    settlement.settle(tokens, batch.clearingPrices, batch.trades, batch.interactions);
    if (sender != solver || !includeCommitment) return;

    for (uint256 i; i < 7; ++i) {
      uint256 expected = balancesBefore[i];
      if (i == batch.sellIndex) expected -= batch.order.sellAmount;
      if (i == batch.buyIndex) expected += batch.received;
      assertEq(tokens[i].balanceOf(address(pool)), expected);
      assertEq(tokens[i].balanceOf(address(settlement)), 0);
    }
    assertEq(pool.totalSupply(), supplyBefore);
    assertEq(pool.balanceOf(address(this)), lpSharesBefore);
    assertEq(batch.order.sellToken.balanceOf(trader), batch.order.sellAmount);
    assertEq(batch.order.buyToken.balanceOf(trader), 0);
    assertGt(_pairInvariant(batch.sellIndex, batch.buyIndex), invariantBefore);
    emit log_named_uint('LP surplus in incoming raw token units', batch.received - batch.order.buyAmount);
  }

  function _prepareBatch(
    bool includeCommitment
  ) internal returns (Batch memory batch) {
    GPv2Interaction.Data[] memory pre;
    bytes memory poolSig;
    (batch.order, pre,, poolSig) = helper.order(address(pool), prices);
    pool.verify(batch.order);
    (batch.sellIndex, batch.buyIndex) = _indices(batch.order);

    // Match a real signed counterparty order at the supplied external price,
    // rounded up by less than one incoming-token unit. Express the pair's
    // clearing-price ratio using the exact matched quantities so neither
    // side needs a settlement dust subsidy.
    batch.received =
      Math.mulDiv(batch.order.sellAmount, prices[batch.sellIndex], prices[batch.buyIndex], Math.Rounding.Ceil);
    assertGt(batch.received, batch.order.buyAmount);
    batch.clearingPrices = prices;
    batch.clearingPrices[batch.sellIndex] = batch.received;
    batch.clearingPrices[batch.buyIndex] = batch.order.sellAmount;
    batch.trades = new GPv2Trade.Data[](2);
    batch.trades[0] = _trade(batch.order, batch.sellIndex, batch.buyIndex, GPv2Signing.Scheme.Eip1271, poolSig);
    batch.trades[1] = _counterTrade(batch);
    batch.interactions[0] = includeCommitment ? pre : new GPv2Interaction.Data[](0);
    batch.interactions[1] = new GPv2Interaction.Data[](0);
    batch.interactions[2] = new GPv2Interaction.Data[](0);
  }

  function _counterTrade(
    Batch memory batch
  ) internal returns (GPv2Trade.Data memory) {
    GPv2Order.Data memory counterOrder = abi.decode(abi.encode(batch.order), (GPv2Order.Data));
    counterOrder.sellToken = batch.order.buyToken;
    counterOrder.buyToken = batch.order.sellToken;
    counterOrder.sellAmount = batch.received;
    counterOrder.buyAmount = batch.order.sellAmount;
    counterOrder.partiallyFillable = false;
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRADER_KEY, counterOrder.hash(settlement.domainSeparator()));
    SevenAssetSettlementToken(address(counterOrder.sellToken)).mint(trader, batch.received);
    address relayer = settlement.vaultRelayer();
    vm.prank(trader);
    counterOrder.sellToken.approve(relayer, batch.received);
    return _trade(counterOrder, batch.buyIndex, batch.sellIndex, GPv2Signing.Scheme.Eip712, abi.encodePacked(r, s, v));
  }

  function _trade(
    GPv2Order.Data memory order,
    uint256 sellIndex,
    uint256 buyIndex,
    GPv2Signing.Scheme scheme,
    bytes memory signature
  ) internal pure returns (GPv2Trade.Data memory trade) {
    trade = GPv2Trade.Data({
      sellTokenIndex: sellIndex,
      buyTokenIndex: buyIndex,
      receiver: order.receiver,
      sellAmount: order.sellAmount,
      buyAmount: order.buyAmount,
      validTo: order.validTo,
      appData: order.appData,
      feeAmount: order.feeAmount,
      flags: GPv2TradeEncoder.encodeFlags(order, scheme),
      executedAmount: order.sellAmount,
      signature: signature
    });
  }

  function _indices(
    GPv2Order.Data memory order
  ) internal view returns (uint256 sellIndex, uint256 buyIndex) {
    for (uint256 i; i < 7; ++i) {
      if (address(tokens[i]) == address(order.sellToken)) sellIndex = i;
      if (address(tokens[i]) == address(order.buyToken)) buyIndex = i;
    }
  }

  function _pairInvariant(
    uint256 first,
    uint256 second
  ) internal view returns (uint256) {
    // Reduce M7's integer weights by their common factor of two, and scale
    // balances to micro-token units to keep the independent product in uint256.
    uint256 firstBalance =
      tokens[first].balanceOf(address(pool)) * 1e6 / 10 ** SevenAssetSettlementToken(address(tokens[first])).decimals();
    uint256 secondBalance = tokens[second].balanceOf(address(pool)) * 1e6 / 10
      ** SevenAssetSettlementToken(address(tokens[second])).decimals();
    return firstBalance ** (weights[first] / 2) * secondBalance ** (weights[second] / 2);
  }
}

contract SevenAssetCoWSettlementTest is SevenAssetSettlementChecks {
  function setUp() public {
    vm.createSelectFork('mainnet', 20_012_063);
    _setUpPool(ISettlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41), 0x423cEc87f19F0778f549846e0801ee267a917935);
  }
}
