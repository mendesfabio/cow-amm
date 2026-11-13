import assert from 'node:assert/strict';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';

const root = fileURLToPath(new URL('../../', import.meta.url));
const statePath = resolve(root, '.local/m7.json');
const chainId = 31338;
const rpcUrl = process.env.LOCAL_RPC_URL ?? 'http://127.0.0.1:8546';
const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
provider.pollingInterval = 100;
// These are public Anvil test accounts, used only on the local demo chain.
const mnemonic = 'test test test test test test test test test test test junk';
const accounts = [0, 1, 2].map((index) =>
  ethers.Wallet.fromMnemonic(mnemonic, `m/44'/60'/0'/0/${index}`).connect(provider),
);
const [manager, solver, trader] = accounts;
const appData = ethers.utils.id('Local seven-asset CoW AMM');
const orderTuple = 'tuple(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,bytes32 kind,bool partiallyFillable,bytes32 sellTokenBalance,bytes32 buyTokenBalance)';
const orderTypes = {
  Order: [
    ['sellToken', 'address'], ['buyToken', 'address'], ['receiver', 'address'],
    ['sellAmount', 'uint256'], ['buyAmount', 'uint256'], ['validTo', 'uint32'],
    ['appData', 'bytes32'], ['feeAmount', 'uint256'], ['kind', 'string'],
    ['partiallyFillable', 'bool'], ['sellTokenBalance', 'string'], ['buyTokenBalance', 'string'],
  ].map(([name, type]) => ({ name, type })),
};

async function artifact(name) {
  return JSON.parse(await readFile(resolve(root, `out/${name}.sol/${name}.json`), 'utf8'));
}

async function contract(name, address, signer = manager) {
  return new ethers.Contract(address, (await artifact(name)).abi, signer);
}

async function deploy(name, args = []) {
  const compiled = await artifact(name);
  const factory = new ethers.ContractFactory(compiled.abi, compiled.bytecode.object, manager);
  const deployed = await factory.deploy(...args);
  await deployed.deployed();
  return deployed;
}

async function save(state) {
  await mkdir(resolve(root, '.local'), { recursive: true });
  await writeFile(`${statePath}.tmp`, `${JSON.stringify(state, null, 2)}\n`);
  await rename(`${statePath}.tmp`, statePath);
}

async function load() {
  const state = JSON.parse(await readFile(statePath, 'utf8'));
  assert.equal(state.chainId, chainId, 'Deployment belongs to another chain');
  assert.notEqual(await provider.getCode(state.pool), '0x', 'Pool missing; rerun local:deploy after restarting Anvil');
  return state;
}

function asOrder(order) {
  return Object.fromEntries(orderTypes.Order.map(({ name }) => [name, order[name]]));
}

async function balances(state, owner = state.pool) {
  return Promise.all(state.tokens.map(async (token) =>
    (await (await contract('LocalStockToken', token.address)).balanceOf(owner)).toString(),
  ));
}

function pairInvariant(state, reserves, first, second) {
  const term = (index) => {
    const token = state.tokens[index];
    const normalized = BigInt(reserves[index]) * 1_000_000n / 10n ** BigInt(token.decimals);
    return normalized ** BigInt(token.weight / 2);
  };
  return term(first) * term(second);
}

async function deployM7() {
  console.log('Deploying CoW authentication, settlement, and vault relayer...');
  const authentication = await deploy('GPv2AllowListAuthentication');
  await (await authentication.initializeManager(manager.address)).wait();
  await (await authentication.addSolver(solver.address)).wait();
  // ERC20 orders use the vault relayer's direct transfer path. This demo
  // deliberately does not configure a Balancer Vault or internal balances.
  const settlement = await deploy('GPv2Settlement', [authentication.address, ethers.constants.AddressZero]);
  const factory = await deploy('BCoWFactory', [settlement.address, appData, manager.address]);
  const helper = await deploy('BCoWHelper', [factory.address]);
  const created = await (await factory.newBPool('Magnificent Seven', 'M7')).wait();
  const poolAddress = created.events.find((event) => event.event === 'LOG_NEW_POOL').args.bPool;
  const pool = await contract('BCoWPool', poolAddress);
  const symbols = ['NVDA', 'MSFT', 'AAPL', 'AMZN', 'GOOGL', 'META', 'TSLA'];
  const decimals = [18, 6, 8, 18, 6, 18, 8];
  const weights = [8, 6, 6, 6, 6, 4, 4];
  const tokens = [];
  for (let index = 0; index < symbols.length; index++) {
    const token = await deploy('LocalStockToken', [symbols[index], symbols[index], decimals[index]]);
    const balance = ethers.utils.parseUnits(String(weights[index] * 100), decimals[index]);
    await (await token.mint(manager.address, balance)).wait();
    await (await token.approve(pool.address, balance)).wait();
    await (await pool.bind(token.address, balance, ethers.utils.parseEther(String(weights[index])))).wait();
    tokens.push({ symbol: symbols[index], address: token.address, decimals: decimals[index], weight: weights[index] });
  }
  await (await pool.setSwapFee('999999000000000000')).wait();
  await (await pool.finalize()).wait();
  const state = {
    chainId, authentication: authentication.address, settlement: settlement.address,
    vaultRelayer: await settlement.vaultRelayer(), factory: factory.address, helper: helper.address,
    pool: pool.address, manager: manager.address, solver: solver.address, trader: trader.address,
    tokens, initialShareSupply: (await pool.totalSupply()).toString(),
    initialLpShares: (await pool.balanceOf(manager.address)).toString(),
  };
  await save(state);
  console.log(`M7 pool: ${state.pool}`);
  console.log(`Settlement: ${state.settlement}`);
  console.log(`Registered solver: ${state.solver}`);
  console.log(`Deployment saved to ${statePath}`);
}

function trade(order, sellTokenIndex, buyTokenIndex, signature, signatureFlag) {
  return {
    sellTokenIndex, buyTokenIndex, receiver: order.receiver, sellAmount: order.sellAmount,
    buyAmount: order.buyAmount, validTo: order.validTo, appData: order.appData, feeAmount: order.feeAmount,
    // Both are sell orders using ERC20 balance markers. Bits 1 and 6 encode
    // partial fill and ERC-1271 respectively; EIP-712 has signature flag zero.
    flags: signatureFlag | (order.partiallyFillable ? 2 : 0),
    executedAmount: order.sellAmount, signature,
  };
}

async function settleM7() {
  const state = await load();
  const settlement = await contract('GPv2Settlement', state.settlement, solver);
  const helper = await contract('BCoWHelper', state.helper);
  const pool = await contract('BCoWPool', state.pool);
  const prices = state.tokens.map((token) => 10n ** BigInt(36 - token.decimals));
  // Synthetic reference prices: all start at $1; NVDA rises 10%.
  prices[0] = prices[0] * 11n / 10n;
  const result = await helper.order(state.pool, prices.map(String));
  const order = asOrder(result[0]);
  await pool.verify(order);
  const indexOf = (address) => state.tokens.findIndex((token) => token.address.toLowerCase() === address.toLowerCase());
  const sellIndex = indexOf(order.sellToken);
  const buyIndex = indexOf(order.buyToken);
  assert.ok(sellIndex >= 0 && buyIndex >= 0 && sellIndex !== buyIndex);
  const sold = BigInt(order.sellAmount.toString());
  const minimum = BigInt(order.buyAmount.toString());
  const received = (sold * prices[sellIndex] + prices[buyIndex] - 1n) / prices[buyIndex];
  assert.ok(received > minimum, 'No positive surplus at the reference price');
  const counterOrder = {
    ...order, sellToken: order.buyToken, buyToken: order.sellToken,
    sellAmount: received.toString(), buyAmount: sold.toString(), partiallyFillable: false,
  };
  const domain = { name: 'Gnosis Protocol', version: 'v2', chainId, verifyingContract: state.settlement };
  const signature = await trader._signTypedData(domain, orderTypes, {
    ...counterOrder, kind: 'sell', sellTokenBalance: 'erc20', buyTokenBalance: 'erc20',
  });
  const incoming = await contract('LocalStockToken', order.buyToken);
  await (await incoming.mint(trader.address, received.toString())).wait();
  await (await incoming.connect(trader).approve(state.vaultRelayer, received.toString())).wait();
  const beforeBalances = await balances(state);
  const beforeTraderBalances = await balances(state, trader.address);
  const clearingPrices = prices.map(String);
  clearingPrices[sellIndex] = received.toString();
  clearingPrices[buyIndex] = sold.toString();
  const poolSignature = ethers.utils.hexConcat([
    state.pool, ethers.utils.defaultAbiCoder.encode([orderTuple], [order]),
  ]);
  const trades = [
    trade(order, sellIndex, buyIndex, poolSignature, 0x40),
    trade(counterOrder, buyIndex, sellIndex, signature, 0),
  ];
  const preInteractions = result[1].map(({ target, value, callData }) => ({ target, value, callData }));
  const receipt = await (await settlement.settle(state.tokens.map((token) => token.address), clearingPrices, trades,
    [preInteractions, [], []])).wait();
  state.lastSettlement = {
    transactionHash: receipt.transactionHash, sellIndex, buyIndex,
    sold: sold.toString(), received: received.toString(), minimum: minimum.toString(),
    beforeBalances, beforeTraderBalances,
  };
  await save(state);
  console.log(`Settled ${state.tokens[sellIndex].symbol} -> ${state.tokens[buyIndex].symbol}: ${receipt.transactionHash}`);
  await verifyM7(state);
}

async function verifyM7(state) {
  state ??= await load();
  const last = state.lastSettlement;
  assert.ok(last, 'Run local:settle before verifying');
  const pool = await contract('BCoWPool', state.pool);
  const authentication = await contract('GPv2AllowListAuthentication', state.authentication);
  const receipt = await provider.getTransactionReceipt(last.transactionHash);
  assert.equal(receipt?.status, 1, 'Settlement transaction did not succeed');
  assert.equal(receipt.from.toLowerCase(), state.solver.toLowerCase());
  assert.equal(await authentication.isSolver(state.solver), true);
  const after = await balances(state);
  const traderAfter = await balances(state, trader.address);
  for (let index = 0; index < 7; index++) {
    let expected = BigInt(last.beforeBalances[index]);
    let expectedTrader = BigInt(last.beforeTraderBalances[index]);
    if (index === last.sellIndex) { expected -= BigInt(last.sold); expectedTrader += BigInt(last.sold); }
    if (index === last.buyIndex) { expected += BigInt(last.received); expectedTrader -= BigInt(last.received); }
    assert.equal(BigInt(after[index]), expected, `${state.tokens[index].symbol} pool balance`);
    assert.equal(BigInt(traderAfter[index]), expectedTrader, `${state.tokens[index].symbol} trader balance`);
  }
  assert.ok((await balances(state, state.settlement)).every((balance) => balance === '0'), 'Tokens left in settlement');
  assert.equal((await pool.totalSupply()).toString(), state.initialShareSupply);
  assert.equal((await pool.balanceOf(state.manager)).toString(), state.initialLpShares);
  const beforeInvariant = pairInvariant(state, last.beforeBalances, last.sellIndex, last.buyIndex);
  const afterInvariant = pairInvariant(state, after, last.sellIndex, last.buyIndex);
  assert.ok(afterInvariant > beforeInvariant, 'Weighted invariant did not increase');
  console.table(state.tokens.map((token, index) => ({
    token: token.symbol, target: `${token.weight / 40 * 100}%`,
    before: ethers.utils.formatUnits(last.beforeBalances[index], token.decimals),
    after: ethers.utils.formatUnits(after[index], token.decimals),
  })));
  console.log('Verified: matched balances, five untouched reserves, unchanged LP shares, and increased weighted invariant.');
  console.log(`LP surplus: ${ethers.utils.formatUnits(BigInt(last.received) - BigInt(last.minimum), state.tokens[last.buyIndex].decimals)} ${state.tokens[last.buyIndex].symbol}`);
}

try {
  assert.equal((await provider.getNetwork()).chainId, chainId, `Expected local chain ${chainId}`);
  switch (process.argv[2]) {
    case 'deploy': await deployM7(); break;
    case 'settle': await settleM7(); break;
    case 'verify': await verifyM7(); break;
    default: throw new Error('Usage: node script/local/m7.mjs deploy|settle|verify');
  }
} catch (error) {
  console.error(error.reason ?? error.message);
  process.exitCode = 1;
}
