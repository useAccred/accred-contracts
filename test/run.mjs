import fs from "node:fs";
import assert from "node:assert/strict";
import ganache from "ganache";
import { BrowserProvider, ContractFactory, NonceManager, Wallet, keccak256, toUtf8Bytes } from "ethers";

const compiled = JSON.parse(fs.readFileSync("test/compiled.json", "utf8"));
const rawProvider = ganache.provider({ chain: { chainId: 31337 }, logging: { quiet: true }, wallet: { deterministic: true, totalAccounts: 5 } });
const provider = new BrowserProvider(rawProvider);
const accounts = Object.values(rawProvider.getInitialAccounts());
const owner = new NonceManager(new Wallet(accounts[0].secretKey, provider));
const alice = new NonceManager(new Wallet(accounts[1].secretKey, provider));
const signer = new NonceManager(new Wallet(accounts[2].secretKey, provider));
const bob = new NonceManager(new Wallet(accounts[3].secretKey, provider));
const ownerAddress = await owner.getAddress();
const aliceAddress = await alice.getAddress();
const signerAddress = await signer.getAddress();
const bobAddress = await bob.getAddress();
const artifact = (name) => compiled[name];
const deploy = async (name, signer_, args = []) => {
  const a = artifact(name);
  return new ContractFactory(a.abi, `0x${a.evm.bytecode.object}`, signer_).deploy(...args).then((c) => c.waitForDeployment());
};
const expectRevert = async (promise, message) => {
  try {
    const tx = await promise;
    if (tx?.wait) await tx.wait();
  } catch (error) {
    const details = [error?.shortMessage, error?.message, error?.error?.message].filter(Boolean).join(" ");
    const isEvmRevert = error?.code === "CALL_EXCEPTION" || /execution reverted|vm exception.*revert/i.test(details);
    const isNonceError = !isEvmRevert && /nonce/i.test(details);
    assert.equal(isNonceError, false, `${message}: unexpected nonce error: ${details}`);
    assert.equal(isEvmRevert, true, `${message}: expected an EVM revert, received: ${details}`);
    return;
  }
  assert.fail(`${message}: expected EVM revert, but call succeeded`);
};
const resyncNonce = async (signer) => {
  signer.reset();
  // BrowserProvider coalesces recent RPC reads; let any pre-failure nonce lookup expire.
  await new Promise((resolve) => setTimeout(resolve, 300));
  const address = await signer.getAddress();
  const rawPending = BigInt(await rawProvider.request({ method: "eth_getTransactionCount", params: [address, "pending"] }));
  const providerPending = BigInt(await provider.getTransactionCount(address, "pending"));
  assert.equal(providerPending, rawPending, "provider nonce agrees with local EVM pending nonce");
  signer.reset();
};

const credit = await deploy("LLMCredit", owner, [ownerAddress]);
const input = await deploy("MockERC20", owner, ["Eligible", "ELG", 18]);
const feeInput = await deploy("MockFeeERC20", owner, [100]);
const project = await deploy("MockERC20", owner, ["Project", "PRJ", 18]);
const usdg = await deploy("MockERC20", owner, ["USDG", "USDG", 6]);

await (await credit.mint(aliceAddress, 1000n * 10n ** 18n)).wait();
const purchase = await deploy("TreasuryCreditPurchase", owner, [credit.target, ownerAddress, signerAddress]);
await (await credit.setMinter(purchase.target, true)).wait();
await (await purchase.connect(signer).setEligibleInput(input.target, true)).wait();
await (await input.mint(aliceAddress, 2n * 10n ** 18n)).wait();
await (await input.connect(alice).approve(purchase.target, 2n * 10n ** 18n)).wait();
const network = await provider.getNetwork();
assert.equal(network.chainId, 31337n, "contract tests must run only on the local EVM chain");
const quote = {
  chainId: network.chainId,
  inputToken: input.target,
  creditToken: credit.target,
  user: aliceAddress,
  inputAmount: 2n * 10n ** 18n,
  creditAmount: 50n * 10n ** 18n,
  minCredits: 50n * 10n ** 18n,
  deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
  nonce: 7n,
};
const domain = { name: "Accred", version: "1", chainId: network.chainId, verifyingContract: purchase.target };
const types = {
  Quote: [
    { name: "chainId", type: "uint256" }, { name: "inputToken", type: "address" }, { name: "creditToken", type: "address" },
    { name: "user", type: "address" }, { name: "inputAmount", type: "uint256" }, { name: "creditAmount", type: "uint256" },
    { name: "minCredits", type: "uint256" }, { name: "deadline", type: "uint256" }, { name: "nonce", type: "uint256" },
  ],
};
const signature = await signer.signTypedData(domain, types, quote);
await (await purchase.connect(alice).settle(quote, signature)).wait();
assert.equal(await credit.balanceOf(aliceAddress), 1050n * 10n ** 18n, "atomic purchase credit amount");
assert.equal(await input.balanceOf(ownerAddress), 2n * 10n ** 18n, "treasury received exact input");
assert.equal(await purchase.usedNonce(7n), true, "nonce consumed");
await expectRevert(purchase.connect(alice).settle.staticCall(quote, signature), "quote replay must revert");
const expiredQuote = { ...quote, nonce: 8n, deadline: 1n };
await expectRevert(purchase.connect(alice).settle.staticCall(expiredQuote, await signer.signTypedData(domain, types, expiredQuote)), "expired quote must revert");
await (await purchase.connect(signer).setEligibleInput(feeInput.target, true)).wait();
await (await feeInput.mint(aliceAddress, 2n * 10n ** 18n)).wait();
await (await feeInput.connect(alice).approve(purchase.target, 2n * 10n ** 18n)).wait();
const feeQuote = { ...quote, inputToken: feeInput.target, nonce: 99n };
await expectRevert(purchase.connect(alice).settle.staticCall(feeQuote, await signer.signTypedData(domain, types, feeQuote)), "fee-on-transfer short receipt");
await expectRevert(credit.connect(alice).mint.staticCall(aliceAddress, 1n), "unauthorized mint");
await (await credit.setBurner(aliceAddress, true)).wait();
await expectRevert(credit.connect(alice).burnFrom.staticCall(ownerAddress, 1n), "burnFrom must require allowance");

const projectPurchase = await deploy("ProjectTokenPurchase", owner, [project.target, credit.target, ownerAddress]);
await (await credit.setMinter(projectPurchase.target, true)).wait();
await (await project.mint(aliceAddress, 100n * 10n ** 18n)).wait();
await (await project.connect(alice).approve(projectPurchase.target, 100n * 10n ** 18n)).wait();
const supplyBefore = await project.totalSupply();
const projectQuote = { chainId: network.chainId, projectToken: project.target, creditToken: credit.target, buyer: aliceAddress, projectAmount: 100n * 10n ** 18n, baseCredits: 123n * 10n ** 18n, deadline: quote.deadline, nonce: 1n };
const projectDomain = { name: "Accred Project Purchase", version: "1", chainId: network.chainId, verifyingContract: projectPurchase.target };
const projectTypes = { Quote: [
  { name: "chainId", type: "uint256" }, { name: "projectToken", type: "address" }, { name: "creditToken", type: "address" },
  { name: "buyer", type: "address" }, { name: "projectAmount", type: "uint256" }, { name: "baseCredits", type: "uint256" },
  { name: "deadline", type: "uint256" }, { name: "nonce", type: "uint256" },
]};
const projectSignature = await owner.signTypedData(projectDomain, projectTypes, projectQuote);
await (await projectPurchase.connect(alice).purchase(projectQuote, projectSignature)).wait();
assert.equal(await project.totalSupply(), supplyBefore - 100n * 10n ** 18n, "project tokens burned");
assert.equal(await credit.balanceOf(aliceAddress), 1185300000000000000000n, "10 percent floor bonus");
await expectRevert(projectPurchase.connect(alice).purchase.staticCall(projectQuote, projectSignature), "project quote replay");
const unauthorizedQuote = { ...projectQuote, buyer: ownerAddress, nonce: 2n };
await expectRevert(projectPurchase.connect(alice).purchase.staticCall(unauthorizedQuote, await owner.signTypedData(projectDomain, projectTypes, unauthorizedQuote)), "buyer binding");
const forgedQuote = { ...projectQuote, baseCredits: 10_000_000n * 10n ** 18n, nonce: 4n };
await expectRevert(projectPurchase.connect(alice).purchase.staticCall(forgedQuote, await alice.signTypedData(projectDomain, projectTypes, forgedQuote)), "arbitrary mint signer");
const expiredProjectQuote = { ...projectQuote, nonce: 3n, deadline: 1n };
await expectRevert(projectPurchase.connect(alice).purchase.staticCall(expiredProjectQuote, await owner.signTypedData(projectDomain, projectTypes, expiredProjectQuote)), "project quote expiry");
async function assertBurnProof(token, nonce) {
  const p = await deploy("ProjectTokenPurchase", owner, [token.target, credit.target, ownerAddress]);
  await (await credit.setMinter(p.target, true)).wait();
  await (await token.mint(aliceAddress, 10n * 10n ** 18n)).wait();
  await (await token.connect(alice).approve(p.target, 10n * 10n ** 18n)).wait();
  const q = { chainId: network.chainId, projectToken: token.target, creditToken: credit.target, buyer: aliceAddress, projectAmount: 10n * 10n ** 18n, baseCredits: 1n * 10n ** 18n, deadline: quote.deadline, nonce };
  const d = { name: "Accred Project Purchase", version: "1", chainId: network.chainId, verifyingContract: p.target };
  await expectRevert(p.connect(alice).purchase.staticCall(q, await owner.signTypedData(d, projectTypes, q)), "burn proof must reject non-destructive token");
}
await assertBurnProof(await deploy("MockNoOpBurnToken", owner), 10n);
await assertBurnProof(await deploy("MockFalseBurnToken", owner), 11n);

{ // dead-address burn variant
  const bp = await deploy("ProjectTokenBurnAddressPurchase", owner, [project.target, credit.target, ownerAddress]);
  await (await credit.setMinter(bp.target, true)).wait();
  await (await project.mint(aliceAddress, 50n * 10n ** 18n)).wait();
  await (await project.connect(alice).approve(bp.target, 50n * 10n ** 18n)).wait();
  const bq = { chainId: network.chainId, projectToken: project.target, creditToken: credit.target, buyer: aliceAddress, projectAmount: 50n * 10n ** 18n, baseCredits: 10n * 10n ** 18n, deadline: quote.deadline, nonce: 77n };
  const bd = { name: "Accred Project Burn Purchase", version: "1", chainId: network.chainId, verifyingContract: bp.target };
  const sig = await owner.signTypedData(bd, projectTypes, bq);
  const creditBefore = await credit.balanceOf(aliceAddress);
  await (await bp.connect(alice).purchase(bq, sig)).wait();
  assert.equal(await project.balanceOf("0x000000000000000000000000000000000000dEaD"), 50n * 10n ** 18n, "tokens sent to dead address");
  assert.equal(await project.balanceOf(bp.target), 0n, "contract never holds tokens");
  assert.equal((await credit.balanceOf(aliceAddress)) - creditBefore, 11n * 10n ** 18n, "10 percent bonus");
  await expectRevert(bp.connect(alice).purchase.staticCall(bq, sig), "burn variant replay");
}

const staking = await deploy("CreditStaking", owner, [credit.target, ownerAddress]);
await (await credit.mint(aliceAddress, 300n * 10n ** 18n)).wait();
await (await credit.connect(alice).approve(staking.target, 300n * 10n ** 18n)).wait();
await (await staking.connect(alice).stake(100n * 10n ** 18n, 3)).wait();
const stakeId = (await staking.nextStakeId()) - 1n;
assert.equal((await staking.stakes(stakeId)).payout, 35000n, "3 day reward micros");
await expectRevert(staking.connect(alice).claim.staticCall(stakeId), "locked stake must revert");
await expectRevert(staking.connect(alice).stake.staticCall(100n * 10n ** 18n, 5), "bad term");
await provider.send("evm_increaseTime", [3 * 24 * 60 * 60]);
await provider.send("evm_mine", []);
const before = await credit.balanceOf(aliceAddress);
await (await staking.connect(alice).claim(stakeId)).wait();
assert.equal((await credit.balanceOf(aliceAddress)) - before, 100n * 10n ** 18n, "principal returned");
await expectRevert(staking.connect(alice).claim.staticCall(stakeId), "double claim");
const sevenId = (await (await staking.connect(alice).stake(100n * 10n ** 18n, 7)).wait(), (await staking.nextStakeId()) - 1n);
const thirtyId = (await (await staking.connect(alice).stake(100n * 10n ** 18n, 30)).wait(), (await staking.nextStakeId()) - 1n);
assert.equal((await staking.stakes(sevenId)).payout, 50000n, "7 day payout");
assert.equal((await staking.stakes(thirtyId)).payout, 99900n, "30 day payout");
await expectRevert(staking.connect(alice).emergencyWithdraw.staticCall(credit.target, aliceAddress, 1n), "only owner withdraws");
await (await staking.emergencyWithdraw(credit.target, ownerAddress, 100n * 10n ** 18n)).wait();
assert.equal(await credit.balanceOf(ownerAddress), 100n * 10n ** 18n, "owner emergency withdraw");

const vault = await deploy("LLMCreditVault", owner, [credit.target, signerAddress]);
await (await credit.connect(alice).approve(vault.target, 25n * 10n ** 18n)).wait();
await (await vault.connect(alice).deposit(25n * 10n ** 18n)).wait();
await expectRevert(vault.connect(alice).deposit.staticCall(0n), "zero deposits rejected");
assert.equal(await vault.credit(), credit.target, "vault credit token");
assert.equal(await vault.deposited(aliceAddress), 25n * 10n ** 18n, "vault deposit balance");
assert.equal(await vault.available(aliceAddress), 25n * 10n ** 18n, "unreserved credits available");
const request1 = keccak256(toUtf8Bytes("llm-request-1"));
await expectRevert(vault.connect(alice).reserve.staticCall(aliceAddress, request1, 20n * 10n ** 18n), "only gateway can reserve");
await expectRevert(vault.connect(signer).reserve.staticCall(aliceAddress, request1, 26n * 10n ** 18n), "reserve cannot exceed available credits");
await expectRevert(vault.connect(signer).reserve.staticCall(aliceAddress, request1, 0n), "zero reservation rejected");
await (await vault.connect(signer).reserve(aliceAddress, request1, 20n * 10n ** 18n)).wait();
assert.equal(await vault.reserved(aliceAddress), 20n * 10n ** 18n, "credits reserved");
assert.equal(await vault.available(aliceAddress), 5n * 10n ** 18n, "held credits excluded from available");
const reservation1 = await vault.reservation(request1);
assert.equal(reservation1.account, aliceAddress, "reservation account");
assert.equal(reservation1.amount, 20n * 10n ** 18n, "reservation amount");
assert.equal(reservation1.status, 1n, "reservation active status");
await expectRevert(vault.connect(alice).withdraw.staticCall(6n * 10n ** 18n), "withdraw cannot take held credits");
await expectRevert(vault.connect(owner).settle.staticCall(request1, 10n * 10n ** 18n), "only gateway can settle");
await expectRevert(vault.connect(signer).settle.staticCall(request1, 21n * 10n ** 18n), "settlement cannot exceed reservation");
const vaultBalanceBeforeBurn = await credit.balanceOf(vault.target);
const supplyBeforeVaultBurn = await credit.totalSupply();
await expectRevert(vault.connect(signer).settle.staticCall(request1, 12n * 10n ** 18n), "burner authorization is required");
assert.equal((await vault.reservation(request1)).status, 1n, "failed burn must preserve active reservation");
assert.equal(await vault.reserved(aliceAddress), 20n * 10n ** 18n, "failed burn must preserve hold accounting");
await (await credit.setBurner(vault.target, true)).wait();
await (await vault.connect(signer).settle(request1, 12n * 10n ** 18n)).wait();
assert.equal(await credit.balanceOf(vault.target), vaultBalanceBeforeBurn - 12n * 10n ** 18n, "settlement burns exact vault balance");
assert.equal(await credit.totalSupply(), supplyBeforeVaultBurn - 12n * 10n ** 18n, "settlement burns exact token supply");
assert.equal(await vault.deposited(aliceAddress), 13n * 10n ** 18n, "only consumed credits leave deposit");
assert.equal(await vault.reserved(aliceAddress), 0n, "settlement releases reservation remainder");
assert.equal(await vault.available(aliceAddress), 13n * 10n ** 18n, "unspent reserved credits become available");
assert.equal((await vault.reservation(request1)).status, 2n, "reservation settled status");
await expectRevert(vault.connect(signer).settle.staticCall(request1, 1n), "settlement cannot replay");
await expectRevert(vault.connect(signer).release.staticCall(request1), "settled reservation cannot release");
await expectRevert(vault.connect(signer).reserve.staticCall(bobAddress, request1, 1n), "request IDs are globally unique");
const request2 = keccak256(toUtf8Bytes("llm-request-2"));
await (await vault.connect(signer).reserve(aliceAddress, request2, 3n * 10n ** 18n)).wait();
await expectRevert(vault.connect(owner).release.staticCall(request2), "only gateway can release");
await (await vault.connect(signer).release(request2)).wait();
assert.equal(await vault.available(aliceAddress), 13n * 10n ** 18n, "release returns full hold");
assert.equal((await vault.reservation(request2)).status, 3n, "reservation released status");
await expectRevert(vault.connect(signer).release.staticCall(request2), "release cannot replay");
await expectRevert(vault.connect(signer).reserve.staticCall(aliceAddress, `0x${"00".repeat(32)}`, 1n), "zero request ID rejected");
await expectRevert(vault.connect(bob).setGateway.staticCall(bobAddress), "only owner rotates gateway");
await (await vault.setGateway(bobAddress)).wait();
const request3 = keccak256(toUtf8Bytes("llm-request-3"));
await expectRevert(vault.connect(signer).reserve.staticCall(aliceAddress, request3, 1n), "rotated gateway revokes old gateway");
await (await vault.connect(bob).reserve(aliceAddress, request3, 1n)).wait();
await (await vault.connect(bob).release(request3)).wait();
const requestFree = keccak256(toUtf8Bytes("llm-request-free-model"));
await (await vault.connect(bob).reserve(aliceAddress, requestFree, 2n * 10n ** 12n)).wait();
const supplyBeforeFreeSettlement = await credit.totalSupply();
await (await vault.connect(bob).settle(requestFree, 0n)).wait();
assert.equal(await credit.totalSupply(), supplyBeforeFreeSettlement, "zero-use settlement skips burning supply");
assert.equal(await vault.deposited(aliceAddress), 13n * 10n ** 18n, "zero-use settlement preserves deposit");
assert.equal(await vault.reserved(aliceAddress), 0n, "zero-use settlement releases the entire reservation");
assert.equal(await vault.available(aliceAddress), 13n * 10n ** 18n, "free-model unused credits become available");
assert.equal((await vault.reservation(requestFree)).status, 2n, "zero-use reservation is terminally settled");
await expectRevert(vault.connect(bob).settle.staticCall(requestFree, 0n), "zero-use settlement cannot replay");
const requestMicrocredit = keccak256(toUtf8Bytes("llm-request-paid-microcredit"));
await (await vault.connect(bob).reserve(aliceAddress, requestMicrocredit, 2n * 10n ** 12n)).wait();
const supplyBeforeMicrocredit = await credit.totalSupply();
await (await vault.connect(bob).settle(requestMicrocredit, 1n * 10n ** 12n)).wait();
assert.equal(await credit.totalSupply(), supplyBeforeMicrocredit - 1n * 10n ** 12n, "one API microcredit consumes 1e12 ERC-20 base units");
assert.equal(await vault.available(aliceAddress), 13n * 10n ** 18n - 1n * 10n ** 12n, "unused microcredit reservation remainder becomes available");
await (await vault.connect(alice).withdraw(10n * 10n ** 18n)).wait();
assert.equal(await vault.deposited(aliceAddress), 3n * 10n ** 18n - 1n * 10n ** 12n, "withdrawal preserves accounting after microcredit usage");

const adversarialCredit = await deploy("MockVaultAdversarialCredit", owner);
const adversarialVault = await deploy("LLMCreditVault", owner, [adversarialCredit.target, signerAddress]);
await (await adversarialCredit.mint(aliceAddress, 2n * 10n ** 18n)).wait();
await (await adversarialCredit.connect(alice).approve(adversarialVault.target, 2n * 10n ** 18n)).wait();
await expectRevert(adversarialVault.connect(alice).deposit.staticCall(2n * 10n ** 18n), "no-op transferFrom must fail receipt proof");
assert.equal(await adversarialVault.deposited(aliceAddress), 0n, "failed receipt records no deposit");
await (await adversarialCredit.setNoOpTransferFrom(false)).wait();
const reentrantDepositData = adversarialVault.interface.encodeFunctionData("deposit", [1n * 10n ** 18n]);
await (await adversarialCredit.setCallback(adversarialVault.target, reentrantDepositData, true)).wait();
await (await adversarialCredit.connect(alice).approve(adversarialVault.target, 2n * 10n ** 18n)).wait();
await (await adversarialVault.connect(alice).deposit(2n * 10n ** 18n)).wait();
assert.equal(await adversarialCredit.callbackSucceeded(), false, "vault reentrancy guard blocks token callback");
const adversarialRequest = keccak256(toUtf8Bytes("adversarial-burn-request"));
await (await adversarialVault.connect(signer).reserve(aliceAddress, adversarialRequest, 2n * 10n ** 18n)).wait();
const adversarialSupplyBefore = await adversarialCredit.totalSupply();
await expectRevert(adversarialVault.connect(signer).settle.staticCall(adversarialRequest, 1n * 10n ** 18n), "no-op burn must fail balance and supply proof");
assert.equal((await adversarialVault.reservation(adversarialRequest)).status, 1n, "failed burn proof leaves request active");
await (await adversarialCredit.setNoOpBurn(false)).wait();
await (await adversarialVault.connect(signer).settle(adversarialRequest, 1n * 10n ** 18n)).wait();
assert.equal(await adversarialCredit.totalSupply(), adversarialSupplyBefore - 1n * 10n ** 18n, "real adversarial-token burn changes supply exactly");

const solanaSettlement = await deploy("SolanaCreditSettlement", owner, [credit.target, signerAddress]);
await (await credit.setMinter(solanaSettlement.target, true)).wait();
const solanaDomain = { name: "Accred Solana Paid Settlement", version: "1", chainId: network.chainId, verifyingContract: solanaSettlement.target };
const solanaTypes = { PaidQuote: [
  { name: "chainId", type: "uint256" }, { name: "creditToken", type: "address" }, { name: "recipient", type: "address" },
  { name: "quoteId", type: "bytes32" }, { name: "paymentId", type: "bytes32" }, { name: "sourcePayer", type: "bytes32" },
  { name: "assetId", type: "bytes32" }, { name: "paidAmount", type: "uint256" }, { name: "creditAmount", type: "uint256" },
  { name: "deadline", type: "uint256" },
]};
const paidQuote = {
  chainId: network.chainId, creditToken: credit.target, recipient: aliceAddress,
  quoteId: keccak256(toUtf8Bytes("solana-quote-1")), paymentId: keccak256(toUtf8Bytes("solana-signature-1")),
  sourcePayer: keccak256(toUtf8Bytes("solana-payer")), assetId: keccak256(toUtf8Bytes("SOL")),
  paidAmount: 1_000_000_000n, creditAmount: 10n * 10n ** 18n, deadline: BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600),
};
const paidSignature = await signer.signTypedData(solanaDomain, solanaTypes, paidQuote);
const aliceBeforeSolanaMint = await credit.balanceOf(aliceAddress);
await (await solanaSettlement.connect(bob).settle(paidQuote, paidSignature)).wait();
assert.equal(await credit.balanceOf(aliceAddress), aliceBeforeSolanaMint + paidQuote.creditAmount, "signed paid Solana settlement mints exact credits");
assert.equal(await solanaSettlement.usedQuoteId(paidQuote.quoteId), true, "Solana quote ID consumed");
assert.equal(await solanaSettlement.usedPaymentId(paidQuote.paymentId), true, "Solana payment ID consumed");
await expectRevert(solanaSettlement.connect(bob).settle.staticCall(paidQuote, paidSignature), "Solana settlement quote replay");
const quoteReplay = { ...paidQuote, paymentId: keccak256(toUtf8Bytes("solana-signature-2")) };
await expectRevert(solanaSettlement.settle.staticCall(quoteReplay, await signer.signTypedData(solanaDomain, solanaTypes, quoteReplay)), "Solana quote ID cannot be reused");
const paymentReplay = { ...paidQuote, quoteId: keccak256(toUtf8Bytes("solana-quote-2")) };
await expectRevert(solanaSettlement.settle.staticCall(paymentReplay, await signer.signTypedData(solanaDomain, solanaTypes, paymentReplay)), "Solana payment ID cannot be reused");
const unsignedQuote = { ...paidQuote, quoteId: keccak256(toUtf8Bytes("unsigned-quote")), paymentId: keccak256(toUtf8Bytes("unsigned-payment")) };
await expectRevert(solanaSettlement.settle.staticCall(unsignedQuote, await alice.signTypedData(solanaDomain, solanaTypes, unsignedQuote)), "only external payment verifier may mint");
const expiredPaidQuote = { ...paidQuote, quoteId: keccak256(toUtf8Bytes("expired-quote")), paymentId: keccak256(toUtf8Bytes("expired-payment")), deadline: 1n };
await expectRevert(solanaSettlement.settle.staticCall(expiredPaidQuote, await signer.signTypedData(solanaDomain, solanaTypes, expiredPaidQuote)), "Solana payment quote expiry");

let nextSwapNonce = 100n;
async function createSwap(account, wallet) {
  const swapQuote = {
    ...quote,
    user: account,
    inputAmount: 1n * 10n ** 18n,
    creditAmount: 50n * 10n ** 18n,
    minCredits: 50n * 10n ** 18n,
    deadline: BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600),
    nonce: nextSwapNonce++,
  };
  await (await input.mint(account, swapQuote.inputAmount)).wait();
  await (await input.connect(wallet).approve(purchase.target, swapQuote.inputAmount)).wait();
  const swapSignature = await signer.signTypedData(domain, types, swapQuote);
  await purchase.connect(wallet).settle.staticCall(swapQuote, swapSignature);
  await (await purchase.connect(wallet).settle(swapQuote, swapSignature)).wait();
  return swapQuote.nonce;
}

const cashback = await deploy("CashbackClaimVault", owner, [usdg.target, 6, ownerAddress, signerAddress, purchase.target]);
await (await usdg.mint(ownerAddress, 20_000_000n)).wait();
await (await usdg.connect(owner).approve(cashback.target, 11_000_000n)).wait();
await (await cashback.fund(11_000_000n)).wait();
const feeCashToken = await deploy("MockFeeERC20", owner, [100]);
const feeCashback = await deploy("CashbackClaimVault", owner, [feeCashToken.target, 18, ownerAddress, signerAddress, purchase.target]);
await (await feeCashToken.mint(ownerAddress, 2n * 10n ** 18n)).wait();
await (await feeCashToken.approve(feeCashback.target, 10n ** 18n)).wait();
await expectRevert(feeCashback.fund.staticCall(10n ** 18n), "fee token funding must be exact");
const cashbackArtifact = artifact("CashbackClaimVault");
const badCashbackData = (await new ContractFactory(cashbackArtifact.abi, `0x${cashbackArtifact.evm.bytecode.object}`, owner)
  .getDeployTransaction(usdg.target, 18, ownerAddress, signerAddress, purchase.target)).data;
await expectRevert(provider.send("eth_estimateGas", [{ from: ownerAddress, data: badCashbackData }]), "cashback decimal mismatch");
const cashbackDomain = { name: "Accred Cashback", version: "1", chainId: network.chainId, verifyingContract: cashback.target };
const cashbackTypes = { Claim: [
  { name: "chainId", type: "uint256" }, { name: "vault", type: "address" }, { name: "user", type: "address" },
  { name: "purchaseNonce", type: "uint256" }, { name: "baseAmount", type: "uint256" }, { name: "rateBps", type: "uint256" },
  { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" },
]};
const cashbackClaim = async (baseAmount, rateBps, nonce, deadline = BigInt(Math.floor(Date.now() / 1000) + 10 * 24 * 3600), user = aliceAddress, wallet = alice) => {
  const purchaseNonce = await createSwap(user, wallet);
  const c = { chainId: network.chainId, vault: cashback.target, user, purchaseNonce, baseAmount, rateBps, nonce, deadline };
  return [c, await signer.signTypedData(cashbackDomain, cashbackTypes, c)];
};
let [cashClaim1, cashSig1] = await cashbackClaim(80_000_000n, 500n, 1n);
const cashbackBefore1 = await usdg.balanceOf(aliceAddress);
await (await cashback.connect(alice).claim(cashClaim1, cashSig1)).wait();
assert.equal(await usdg.balanceOf(aliceAddress), cashbackBefore1 + 4_000_000n, "5% signed cashback payout from funded vault");
const nonswapClaim = {
  chainId: network.chainId, vault: cashback.target, user: aliceAddress, purchaseNonce: 999_999n,
  baseAmount: 20_000_000n, rateBps: 500n, nonce: 21n, deadline: BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600),
};
const nonswapSignature = await signer.signTypedData(cashbackDomain, cashbackTypes, nonswapClaim);
await expectRevert(cashback.connect(alice).claim.staticCall(nonswapClaim, nonswapSignature), "cashback requires an on-chain crypto-to-credit swap");
assert.equal(await cashback.usedNonce(21n), false, "failed nonswap claim consumes no nonce");
await expectRevert(cashback.connect(alice).claim.staticCall(cashClaim1, cashSig1), "cashback replay");
const actionReplay = { ...cashClaim1, nonce: 20n };
const actionReplaySig = await signer.signTypedData(cashbackDomain, cashbackTypes, actionReplay);
await expectRevert(cashback.connect(alice).claim.staticCall(actionReplay, actionReplaySig), "cashback economic action replay");
let [cashClaim2, cashSig2] = await cashbackClaim(120_000_000n, 500n, 2n);
await (await cashback.connect(alice).claim(cashClaim2, cashSig2)).wait();
let [overCap, overCapSig] = await cashbackClaim(20n, 500n, 3n);
await expectRevert(cashback.connect(alice).claim.staticCall(overCap, overCapSig), "cashback cap");
let [wrongBuyer, wrongBuyerSig] = await cashbackClaim(20n, 500n, 4n);
wrongBuyer = { ...wrongBuyer, user: ownerAddress };
wrongBuyerSig = await signer.signTypedData(cashbackDomain, cashbackTypes, wrongBuyer);
await expectRevert(cashback.connect(owner).claim.staticCall(wrongBuyer, wrongBuyerSig), "cashback must match purchase buyer");
let [expiredCash, expiredSig] = await cashbackClaim(20n, 500n, 5n, 1n);
await expectRevert(cashback.connect(alice).claim.staticCall(expiredCash, expiredSig), "cashback expiry");
let [lowRateCash, lowRateSig] = await cashbackClaim(100_000_000n, 199n, 6n);
await expectRevert(cashback.connect(alice).claim.staticCall(lowRateCash, lowRateSig), "cashback rate below 2 percent");
let [highRateCash, highRateSig] = await cashbackClaim(100_000_000n, 501n, 7n);
await expectRevert(cashback.connect(alice).claim.staticCall(highRateCash, highRateSig), "cashback rate above 5 percent");
await provider.send("evm_increaseTime", [3600]);
await provider.send("evm_mine", []);
const balanceAtBoundary = await usdg.balanceOf(aliceAddress);
let [boundaryClaim, boundarySig] = await cashbackClaim(20_000_000n, 500n, 8n);
await (await cashback.connect(alice).claim(boundaryClaim, boundarySig)).wait();
assert.equal(await usdg.balanceOf(aliceAddress), balanceAtBoundary + 1_000_000n, "exact cooldown boundary payout");
await (await usdg.connect(owner).approve(cashback.target, 11n)).wait();
await (await cashback.fund(11n)).wait();
const emptyCashback = await deploy("CashbackClaimVault", owner, [usdg.target, 6, ownerAddress, signerAddress, purchase.target]);
const emptyDomain = { ...cashbackDomain, verifyingContract: emptyCashback.target };
const unfundedPurchaseNonce = await createSwap(aliceAddress, alice);
const unfundedClaim = { chainId: network.chainId, vault: emptyCashback.target, user: aliceAddress, purchaseNonce: unfundedPurchaseNonce, baseAmount: 20_000_000n, rateBps: 500n, nonce: 9n, deadline: BigInt(Math.floor(Date.now() / 1000) + 10 * 24 * 3600) };
const unfundedSig = await signer.signTypedData(emptyDomain, cashbackTypes, unfundedClaim);
await expectRevert(emptyCashback.connect(alice).claim.staticCall(unfundedClaim, unfundedSig), "cashback unfunded");
let [partialCap, partialCapSig] = await cashbackClaim(180_000_020n, 500n, 10n);
await expectRevert(cashback.connect(alice).claim.staticCall(partialCap, partialCapSig), "cashback partial cap");
for (let i = 0; i < 11; i++) {
  const [tinyClaim, tinySig] = await cashbackClaim(50n, 200n, 100n + BigInt(i), undefined, bobAddress, bob);
  await (await cashback.connect(bob).claim(tinyClaim, tinySig)).wait();
}
assert.equal(await usdg.balanceOf(bobAddress), 11n, "11 tiny claims accepted");

const redeemer = await deploy("LLMCreditRedeemer", owner, [credit.target, usdg.target, signerAddress]);
const redemptionFunding = 2_000_000n;
await (await usdg.connect(owner).approve(redeemer.target, redemptionFunding)).wait();
await (await redeemer.fund(redemptionFunding)).wait();
const redeemDomain = { name: "Accred Credit Redeemer", version: "1", chainId: network.chainId, verifyingContract: redeemer.target };
const redeemTypes = { RedeemQuote: [
  { name: "chainId", type: "uint256" }, { name: "redeemer", type: "address" },
  { name: "creditToken", type: "address" }, { name: "usdgToken", type: "address" },
  { name: "wallet", type: "address" }, { name: "creditAmount", type: "uint256" },
  { name: "usdgAmount", type: "uint256" }, { name: "deadline", type: "uint256" },
  { name: "quoteId", type: "bytes32" }, { name: "actionId", type: "bytes32" },
]};
async function redeemQuote(contract, walletAddress, creditAmount, usdgAmount, quoteName, actionName, deadline = BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600), creditToken = credit.target, usdgToken = usdg.target) {
  const quoteId = keccak256(toUtf8Bytes(quoteName));
  const actionId = keccak256(toUtf8Bytes(actionName));
  const quoteData = {
    chainId: network.chainId, redeemer: contract.target, creditToken, usdgToken,
    wallet: walletAddress, creditAmount, usdgAmount, deadline, quoteId, actionId,
  };
  return { quoteId, actionId, creditAmount, usdgAmount, deadline, signature: await signer.signTypedData(
    { ...redeemDomain, verifyingContract: contract.target }, redeemTypes, quoteData,
  ) };
}
const redeemCall = (contract, wallet, q, overrides = {}) => contract.connect(wallet).redeem(
  q.quoteId, q.actionId, q.creditAmount, q.usdgAmount, q.deadline, q.signature, overrides,
);
const redeemStaticCall = (contract, wallet, q) => contract.connect(wallet).redeem.staticCall(
  q.quoteId, q.actionId, q.creditAmount, q.usdgAmount, q.deadline, q.signature,
);
const firstRedeem = await redeemQuote(redeemer, aliceAddress, 2n * 10n ** 18n, 1_000_000n, "redeem-quote-1", "redeem-action-1");
await (await credit.connect(alice).approve(redeemer.target, firstRedeem.creditAmount)).wait();
const aliceCreditsBeforeUnapprovedRedeem = await credit.balanceOf(aliceAddress);
const supplyBeforeUnapprovedRedeem = await credit.totalSupply();
await expectRevert(redeemCall(redeemer, alice, firstRedeem, { gasLimit: 1_000_000n }), "redeemer requires explicit LLMCredit burner authorization");
// Ganache may reject a reverting send before mining it; resync whether or not it mined.
await resyncNonce(alice);
assert.equal(await credit.balanceOf(aliceAddress), aliceCreditsBeforeUnapprovedRedeem, "failed burn role rolls back credit receipt");
assert.equal(await credit.totalSupply(), supplyBeforeUnapprovedRedeem, "failed burn role does not change supply");
assert.equal(await redeemer.usedQuoteId(firstRedeem.quoteId), false, "failed redemption does not consume quote");
assert.equal(await redeemer.usedActionId(firstRedeem.actionId), false, "failed redemption does not consume action");
await (await credit.setBurner(redeemer.target, true)).wait();
const aliceUsdgbeforeRedeem = await usdg.balanceOf(aliceAddress);
await (await redeemCall(redeemer, alice, firstRedeem)).wait();
assert.equal(await credit.balanceOf(aliceAddress), aliceCreditsBeforeUnapprovedRedeem - firstRedeem.creditAmount, "redeemer pulls exact wallet credits");
assert.equal(await credit.totalSupply(), supplyBeforeUnapprovedRedeem - firstRedeem.creditAmount, "redemption burns exact credit supply");
assert.equal(await usdg.balanceOf(aliceAddress), aliceUsdgbeforeRedeem + firstRedeem.usdgAmount, "redeemer pays exact USDG quote");
assert.equal(await redeemer.availableReserve(), redemptionFunding - firstRedeem.usdgAmount, "prefunded reserve falls by exact payout");
assert.equal(await redeemer.usedQuoteId(firstRedeem.quoteId), true, "redemption quote consumed");
assert.equal(await redeemer.usedActionId(firstRedeem.actionId), true, "redemption action consumed");
await expectRevert(redeemStaticCall(redeemer, alice, firstRedeem), "redemption quote cannot replay");
const actionReplayRedeem = await redeemQuote(redeemer, aliceAddress, 1n * 10n ** 18n, 500_000n, "redeem-quote-2", "redeem-action-1");
await expectRevert(redeemStaticCall(redeemer, alice, actionReplayRedeem), "economic action cannot redeem twice");
const quoteReplayRedeem = await redeemQuote(redeemer, aliceAddress, 1n * 10n ** 18n, 500_000n, "redeem-quote-1", "redeem-action-2");
await expectRevert(redeemStaticCall(redeemer, alice, quoteReplayRedeem), "quote ID cannot be reused");
const wrongWalletRedeem = await redeemQuote(redeemer, bobAddress, 1n * 10n ** 18n, 500_000n, "redeem-wrong-wallet", "redeem-wrong-wallet-action");
await expectRevert(redeemStaticCall(redeemer, alice, wrongWalletRedeem), "redemption quote binds caller wallet");
const expiredRedeem = await redeemQuote(redeemer, aliceAddress, 1n * 10n ** 18n, 500_000n, "redeem-expired", "redeem-expired-action", 1n);
await expectRevert(redeemStaticCall(redeemer, alice, expiredRedeem), "redemption deadline");
await expectRevert(redeemer.connect(alice).withdraw.staticCall(1n), "only owner can withdraw reserve");
await expectRevert(redeemer.withdraw.staticCall(redemptionFunding), "owner cannot withdraw already-paid reserve");
await (await redeemer.withdraw(await redeemer.availableReserve())).wait();
assert.equal(await redeemer.availableReserve(), 0n, "owner withdraws only remaining available USDG");

const adversarialUsdG = await deploy("MockVaultAdversarialUSDG", owner);
const adversarialUsdGRedeemer = await deploy("LLMCreditRedeemer", owner, [credit.target, adversarialUsdG.target, signerAddress]);
await (await adversarialUsdG.mint(ownerAddress, 1_000_000n)).wait();
await (await adversarialUsdG.approve(adversarialUsdGRedeemer.target, 1_000_000n)).wait();
await expectRevert(adversarialUsdGRedeemer.fund.staticCall(1_000_000n), "no-op USDG funding must fail exact receipt proof");
assert.equal(await adversarialUsdGRedeemer.availableReserve(), 0n, "failed no-op USDG funding records no reserve");
await (await adversarialUsdG.setNoOpTransferFrom(false)).wait();
await (await adversarialUsdG.approve(adversarialUsdGRedeemer.target, 1_000_000n)).wait();
await (await adversarialUsdGRedeemer.fund(1_000_000n)).wait();
await (await credit.setBurner(adversarialUsdGRedeemer.target, true)).wait();
const badPayoutRedeem = await redeemQuote(
  adversarialUsdGRedeemer, aliceAddress, 1n * 10n ** 18n, 500_000n,
  "redeem-bad-payout", "redeem-bad-payout-action", undefined, credit.target, adversarialUsdG.target,
);
await (await credit.connect(alice).approve(adversarialUsdGRedeemer.target, badPayoutRedeem.creditAmount)).wait();
const creditSupplyBeforeBadPayout = await credit.totalSupply();
const aliceCreditBeforeBadPayout = await credit.balanceOf(aliceAddress);
await expectRevert(redeemCall(adversarialUsdGRedeemer, alice, badPayoutRedeem, { gasLimit: 1_000_000n }), "no-op USDG payout must fail recipient receipt proof");
await resyncNonce(alice);
assert.equal(await credit.totalSupply(), creditSupplyBeforeBadPayout, "failed USDG receipt rolls back credit burn");
assert.equal(await credit.balanceOf(aliceAddress), aliceCreditBeforeBadPayout, "failed USDG receipt rolls back credit transfer");
assert.equal(await adversarialUsdGRedeemer.usedQuoteId(badPayoutRedeem.quoteId), false, "failed USDG payout leaves quote reusable");
await (await adversarialUsdG.setNoOpTransfer(false)).wait();
const aliceBeforeAdversarialUsdG = await adversarialUsdG.balanceOf(aliceAddress);
await (await redeemCall(adversarialUsdGRedeemer, alice, badPayoutRedeem)).wait();
assert.equal(await adversarialUsdG.balanceOf(aliceAddress), aliceBeforeAdversarialUsdG + badPayoutRedeem.usdgAmount, "actual USDG transfer delivers exact payout");

const bobVault = await deploy("LLMCreditVault", owner, [credit.target, signerAddress]);
const bobWalletCredits = await credit.balanceOf(bobAddress);
await (await credit.connect(bob).approve(bobVault.target, bobWalletCredits)).wait();
await (await bobVault.connect(bob).deposit(bobWalletCredits)).wait();
await (await bobVault.connect(signer).reserve(bobAddress, keccak256(toUtf8Bytes("bob-api-reservation")), bobWalletCredits)).wait();
await (await usdg.connect(owner).approve(redeemer.target, 500_000n)).wait();
await (await redeemer.fund(500_000n)).wait();
await (await credit.connect(bob).approve(redeemer.target, 1n * 10n ** 18n)).wait();
const vaultCreditsCannotRedeem = await redeemQuote(redeemer, bobAddress, 1n * 10n ** 18n, 500_000n, "vault-only-credits", "vault-only-action");
await expectRevert(redeemCall(redeemer, bob, vaultCreditsCannotRedeem, { gasLimit: 1_000_000n }), "redeemer cannot consume deposited or reserved API credits");
await resyncNonce(bob);
assert.equal(await bobVault.reserved(bobAddress), bobWalletCredits, "redeem does not alter API reservation");
assert.equal(await credit.balanceOf(bobAddress), 0n, "reserved API credits remain in vault");

console.log("PASS: purchase/burn proof, API reservations, signed Solana settlement, cashback, and wallet-credit redemption");