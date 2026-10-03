// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "CreditTerminal.sol";

interface Vm {
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 timestamp) external;
    function prank(address sender) external;
    function stopPrank() external;
}

contract CreditTerminalTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    LLMCredit internal credit;
    MockERC20 internal input;
    MockERC20 internal project;
    MockERC20 internal usdg;
    address internal alice = address(0xA11CE);
    uint256 internal signerKey = 0xBEEF;

    function setUp() public {
        credit = new LLMCredit(address(this));
        input = new MockERC20("Eligible", "ELG", 18);
        project = new MockERC20("Project", "PRJ", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        credit.mint(alice, 1_000 ether);
    }
    function testProjectPurchaseBurnsAndAddsExactTenPercent() public {
        ProjectTokenPurchase p = new ProjectTokenPurchase(project, credit, vm.addr(signerKey));
        credit.setMinter(address(p), true);
        project.mint(alice, 100 ether);
        _callApprove(project, alice, address(p), 100 ether);
        uint256 beforeSupply = project.totalSupply();
        ProjectTokenPurchase.Quote memory q = ProjectTokenPurchase.Quote(block.chainid, address(project), address(credit), alice, 100 ether, 123 ether, block.timestamp + 1 days, 1);
        _callPurchase(p, alice, q, _signProject(p, q));
        require(credit.balanceOf(alice) == 1_135 ether + 300000000000000000, "bonus rounding");
        require(project.totalSupply() == beforeSupply - 100 ether, "tokens were not burned");
    }
    function testStakeLocksPrincipalOnly() public {
        CreditStaking staking = new CreditStaking(credit, address(this));
        credit.mint(address(this), 100 ether);
        _callApprove(credit, address(this), address(staking), 100 ether);
        _expectRevertStake(staking, 100 ether, 5);
        uint256 id = staking.stake(100 ether, 3);
        _expectRevertClaim(staking, id);
        vm.warp(block.timestamp + 3 days);
        staking.claim(id);
        (, , uint256 reward, , ) = staking.stakes(id);
        require(reward == 35000, "wrong reward record");
        require(credit.balanceOf(address(this)) == 100 ether, "credits not returned");
    }
    function testVaultReservesOnlyAvailableCreditsAndBurnsExactUsage() public {
        address gateway = vm.addr(signerKey);
        LLMCreditVault vault = new LLMCreditVault(credit, gateway);
        credit.setBurner(address(vault), true);
        _callApprove(credit, alice, address(vault), 25 ether);
        _callDeposit(vault, alice, 25 ether);
        require(vault.deposited(alice) == 25 ether, "deposit missing");
        _callReserve(vault, gateway, alice, keccak256("request-1"), 20 ether);
        require(vault.available(alice) == 5 ether, "reservation not held");
        _expectRevertWithdraw(vault, alice, 6 ether);
        uint256 supplyBefore = credit.totalSupply();
        _callSettleVault(vault, gateway, keccak256("request-1"), 12 ether);
        require(credit.totalSupply() == supplyBefore - 12 ether, "settlement burn supply");
        require(credit.balanceOf(address(vault)) == 13 ether, "settlement burn balance");
        require(vault.deposited(alice) == 13 ether && vault.available(alice) == 13 ether, "settlement accounting");
        _callReserve(vault, gateway, alice, keccak256("request-2"), 3 ether);
        _callReleaseVault(vault, gateway, keccak256("request-2"));
        require(vault.available(alice) == 13 ether, "release restores availability");
    }
    function testQuoteReplayAndExpiryProtection() public {
        TreasuryCreditPurchase purchase = new TreasuryCreditPurchase(credit, address(this), vm.addr(signerKey));
        credit.setMinter(address(purchase), true);
        vm.prank(vm.addr(signerKey)); purchase.setEligibleInput(address(input), true); vm.stopPrank();
        input.mint(alice, 2 ether);
        _callApprove(input, alice, address(purchase), 2 ether);
        TreasuryCreditPurchase.Quote memory q = TreasuryCreditPurchase.Quote(
            block.chainid, address(input), address(credit), alice, 2 ether, 50 ether, 50 ether, block.timestamp + 1 days, 7
        );
        bytes memory sig = _sign(purchase, q);
        _callSettle(purchase, alice, q, sig);
        require(credit.balanceOf(alice) == 1_050 ether, "credit delivery");
        _expectRevertSettle(purchase, alice, q, sig);
        q.nonce = 8; q.deadline = block.timestamp - 1;
        _expectRevertSettle(purchase, alice, q, _sign(purchase, q));
    }
    function _sign(TreasuryCreditPurchase p, TreasuryCreditPurchase.Quote memory q) internal returns (bytes memory) {
        bytes32 domain = p.DOMAIN_SEPARATOR();
        bytes32 typeHash = p.QUOTE_TYPEHASH();
        bytes32 structHash = keccak256(abi.encode(typeHash, q.chainId, q.inputToken, q.creditToken, q.user, q.inputAmount, q.creditAmount, q.minCredits, q.deadline, q.nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }
    function _callApprove(MockERC20 token, address from, address spender, uint256 amount) internal {
        vm.prank(from); token.approve(spender, amount); vm.stopPrank();
    }
    function _callApprove(LLMCredit token, address from, address spender, uint256 amount) internal {
        vm.prank(from); token.approve(spender, amount); vm.stopPrank();
    }
    function _callPurchase(ProjectTokenPurchase p, address from, ProjectTokenPurchase.Quote memory q, bytes memory sig) internal {
        vm.prank(from); p.purchase(q, sig); vm.stopPrank();
    }
    function _signProject(ProjectTokenPurchase p, ProjectTokenPurchase.Quote memory q) internal returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(p.QUOTE_TYPEHASH(), q.chainId, q.projectToken, q.creditToken, q.buyer, q.projectAmount, q.baseCredits, q.deadline, q.nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", p.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }
    function _callDeposit(LLMCreditVault v, address from, uint256 amount) internal { vm.prank(from); v.deposit(amount); vm.stopPrank(); }
    function _callReserve(LLMCreditVault v, address gateway, address account, bytes32 id, uint256 amount) internal { vm.prank(gateway); v.reserve(account, id, amount); vm.stopPrank(); }
    function _callSettleVault(LLMCreditVault v, address gateway, bytes32 id, uint256 amount) internal { vm.prank(gateway); v.settle(id, amount); vm.stopPrank(); }
    function _callReleaseVault(LLMCreditVault v, address gateway, bytes32 id) internal { vm.prank(gateway); v.release(id); vm.stopPrank(); }
    function _expectRevertWithdraw(LLMCreditVault v, address from, uint256 amount) internal {
        vm.prank(from);
        (bool ok,) = address(v).call(abi.encodeWithSelector(v.withdraw.selector, amount));
        vm.stopPrank();
        require(!ok, "withdraw should respect held credits");
    }
    function _callSettle(TreasuryCreditPurchase p, address from, TreasuryCreditPurchase.Quote memory q, bytes memory sig) internal {
        vm.prank(from); p.settle(q, sig); vm.stopPrank();
    }
    function _expectRevertStake(CreditStaking s, uint256 amount, uint256 term) internal { (bool ok,) = address(s).call(abi.encodeWithSelector(s.stake.selector, amount, term)); require(!ok, "expected stake revert"); }
    function _expectRevertClaim(CreditStaking s, uint256 id) internal { (bool ok,) = address(s).call(abi.encodeWithSelector(s.claim.selector, id)); require(!ok, "expected claim revert"); }
    function _expectRevertSettle(TreasuryCreditPurchase p, address from, TreasuryCreditPurchase.Quote memory q, bytes memory sig) internal {
        vm.prank(from);
        (bool ok,) = address(p).call(abi.encodeWithSelector(p.settle.selector, q, sig));
        vm.stopPrank();
        require(!ok, "expected settle revert");
    }
}