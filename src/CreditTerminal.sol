// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 implementation used by the local contract suite.
contract ERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_; symbol = symbol_; decimals = decimals_;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount); return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        require(permitted >= amount, "ERC20: allowance");
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        _transfer(from, to, amount); return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: zero recipient");
        require(balanceOf[from] >= amount, "ERC20: balance");
        unchecked { balanceOf[from] -= amount; balanceOf[to] += amount; }
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ERC20: zero recipient");
        totalSupply += amount; balanceOf[to] += amount; emit Transfer(address(0), to, amount);
    }
    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: balance");
        unchecked { balanceOf[from] -= amount; totalSupply -= amount; }
        emit Transfer(from, address(0), amount);
    }
}

contract LLMCredit is ERC20 {
    address public owner;
    mapping(address => bool) public minters;
    mapping(address => bool) public burners;
    modifier onlyOwner() { require(msg.sender == owner, "Credit: owner"); _; }
    modifier onlyMinter() { require(minters[msg.sender], "Credit: minter"); _; }
    constructor(address owner_) ERC20("LLM Credit", "CREDIT", 18) {
        require(owner_ != address(0), "Credit: zero owner"); owner = owner_; minters[owner_] = true;
    }
    function setMinter(address account, bool allowed) external onlyOwner { minters[account] = allowed; }
    function setBurner(address account, bool allowed) external onlyOwner { burners[account] = allowed; }
    function mint(address to, uint256 amount) external onlyMinter { _mint(to, amount); }
    function burn(uint256 amount) external { require(burners[msg.sender] || minters[msg.sender], "Credit: burner"); _burn(msg.sender, amount); }
    function burnFrom(address from, uint256 amount) external {
        require(burners[msg.sender] || minters[msg.sender], "Credit: burner");
        uint256 permitted = allowance[from][msg.sender];
        require(permitted >= amount, "Credit: allowance");
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        _burn(from, amount);
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}

contract MockFeeERC20 is ERC20 {
    uint256 public immutable feeBps;
    constructor(uint256 feeBps_) ERC20("Fee Token", "FEE", 18) { feeBps = feeBps_; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function _transfer(address from, address to, uint256 amount) internal override {
        require(balanceOf[from] >= amount, "ERC20: balance");
        uint256 fee = amount * feeBps / 10000;
        unchecked { balanceOf[from] -= amount; balanceOf[to] += amount - fee; totalSupply -= fee; }
        emit Transfer(from, to, amount - fee);
    }
}

contract MockNoOpBurnToken is ERC20 {
    constructor() ERC20("No Op Project", "NOP", 18) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256) external returns (bool) { return true; }
}

contract MockFalseBurnToken is ERC20 {
    constructor() ERC20("False Project", "FLB", 18) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256) external returns (bool) { return false; }
}

/// @dev Local adversarial fixture for exact vault receipt and burn assertions.
contract MockVaultAdversarialCredit {
    string public constant name = "Adversarial Credit";
    string public constant symbol = "BAD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public noOpTransferFrom = true;
    bool public noOpBurn = true;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransferFrom;
    bool public callbackSucceeded;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function setNoOpTransferFrom(bool enabled) external { noOpTransferFrom = enabled; }
    function setNoOpBurn(bool enabled) external { noOpBurn = enabled; }
    function setCallback(address target, bytes calldata data, bool enabled) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnTransferFrom = enabled;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BadCredit: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (callbackOnTransferFrom) (callbackSucceeded,) = callbackTarget.call(callbackData);
        if (noOpTransferFrom) return true;
        uint256 permitted = allowance[from][msg.sender];
        require(permitted >= amount && balanceOf[from] >= amount, "BadCredit: allowance");
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function burn(uint256 amount) external {
        if (noOpBurn) return;
        require(balanceOf[msg.sender] >= amount, "BadCredit: balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}

library SafeTransfer {
    function transferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer: transferFrom failed");
    }
    function transfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer: transfer failed");
    }
}

library FullMath {
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / denominator;
            require(denominator > prod1, "Math: overflow");
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }
}

contract TreasuryCreditPurchase {
    using SafeTransfer for address;
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(uint256 chainId,address inputToken,address creditToken,address user,uint256 inputAmount,uint256 creditAmount,uint256 minCredits,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    LLMCredit public immutable credit;
    address public immutable treasury;
    address public immutable quoteSigner;
    mapping(address => bool) public eligibleInput;
    mapping(uint256 => bool) public usedNonce;
    struct PurchaseReceipt { address buyer; address inputToken; uint256 inputAmount; uint256 creditAmount; }
    mapping(uint256 => PurchaseReceipt) public receipts;
    event QuoteSettled(address indexed user, address indexed inputToken, uint256 inputAmount, uint256 credits, uint256 nonce);

    struct Quote {
        uint256 chainId; address inputToken; address creditToken; address user;
        uint256 inputAmount; uint256 creditAmount; uint256 minCredits; uint256 deadline; uint256 nonce;
    }
    constructor(LLMCredit c, address treasury_, address signer_) {
        require(address(c) != address(0) && treasury_ != address(0) && signer_ != address(0), "Purchase: zero");
        credit = c; treasury = treasury_; quoteSigner = signer_;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Accred"), keccak256("1"), block.chainid, address(this)
        ));
    }
    function setEligibleInput(address token, bool allowed) external {
        require(msg.sender == quoteSigner, "Purchase: admin");
        eligibleInput[token] = allowed;
    }
    function settle(Quote calldata q, bytes calldata signature) external {
        require(block.timestamp <= q.deadline, "Purchase: expired");
        require(q.chainId == block.chainid && q.creditToken == address(credit), "Purchase: domain");
        require(q.user == msg.sender && eligibleInput[q.inputToken], "Purchase: authorization");
        require(q.creditAmount >= q.minCredits && !usedNonce[q.nonce], "Purchase: quote");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(
            QUOTE_TYPEHASH, q.chainId, q.inputToken, q.creditToken, q.user, q.inputAmount, q.creditAmount, q.minCredits, q.deadline, q.nonce
        ))));
        require(_recover(digest, signature) == quoteSigner, "Purchase: signature");
        usedNonce[q.nonce] = true;
        uint256 treasuryBefore = ERC20(q.inputToken).balanceOf(treasury);
        q.inputToken.transferFrom(msg.sender, treasury, q.inputAmount);
        require(ERC20(q.inputToken).balanceOf(treasury) - treasuryBefore == q.inputAmount, "Purchase: short receipt");
        receipts[q.nonce] = PurchaseReceipt(msg.sender, q.inputToken, q.inputAmount, q.creditAmount);
        credit.mint(msg.sender, q.creditAmount);
        emit QuoteSettled(msg.sender, q.inputToken, q.inputAmount, q.creditAmount, q.nonce);
    }
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "Purchase: signature length");
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := calldataload(sig.offset) s := calldataload(add(sig.offset, 32)) v := byte(0, calldataload(add(sig.offset, 64))) }
        require(v == 27 || v == 28, "Purchase: signature v");
        require(uint256(s) <= 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0, "Purchase: high s");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Purchase: bad signature");
        return signer;
    }
}

contract ProjectTokenPurchase {
    using SafeTransfer for address;
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(uint256 chainId,address projectToken,address creditToken,address buyer,uint256 projectAmount,uint256 baseCredits,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    ERC20 public immutable projectToken;
    LLMCredit public immutable credit;
    address public immutable owner;
    mapping(uint256 => bool) public usedNonce;
    event ProjectPurchase(address indexed buyer, uint256 projectAmount, uint256 baseCredits, uint256 bonusCredits);
    constructor(ERC20 projectToken_, LLMCredit credit_, address owner_) {
        require(address(projectToken_) != address(0) && address(credit_) != address(0) && owner_ != address(0), "Project: zero");
        projectToken = projectToken_; credit = credit_; owner = owner_;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Accred Project Purchase"), keccak256("1"), block.chainid, address(this)
        ));
    }
    struct Quote {
        uint256 chainId; address projectToken; address creditToken; address buyer;
        uint256 projectAmount; uint256 baseCredits; uint256 deadline; uint256 nonce;
    }
    function purchase(Quote calldata q, bytes calldata signature) external {
        require(q.chainId == block.chainid && q.projectToken == address(projectToken) && q.creditToken == address(credit), "Project: domain");
        require(q.buyer == msg.sender && q.projectAmount > 0 && q.baseCredits > 0, "Project: buyer");
        require(block.timestamp <= q.deadline && !usedNonce[q.nonce], "Project: quote");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(
            QUOTE_TYPEHASH, q.chainId, q.projectToken, q.creditToken, q.buyer, q.projectAmount, q.baseCredits, q.deadline, q.nonce
        ))));
        require(_recover(digest, signature) == owner, "Project: signature");
        usedNonce[q.nonce] = true;
        uint256 beforeBalance = projectToken.balanceOf(address(this));
        address(projectToken).transferFrom(msg.sender, address(this), q.projectAmount);
        require(projectToken.balanceOf(address(this)) - beforeBalance == q.projectAmount, "Project: short receipt");
        uint256 projectAmount = q.projectAmount;
        uint256 baseCredits = q.baseCredits;
        uint256 supplyBefore = projectToken.totalSupply();
        uint256 balanceBeforeBurn = projectToken.balanceOf(address(this));
        (bool burned,) = address(projectToken).call(abi.encodeWithSignature("burn(uint256)", projectAmount));
        require(burned, "Project: burn failed");
        require(projectToken.balanceOf(address(this)) + projectAmount == balanceBeforeBurn, "Project: burn balance");
        require(projectToken.totalSupply() + projectAmount == supplyBefore, "Project: burn supply");
        uint256 bonus = baseCredits / 10; // exact integer floor; no fractional credit is created
        credit.mint(msg.sender, baseCredits + bonus);
        emit ProjectPurchase(msg.sender, projectAmount, baseCredits, bonus);
    }
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "Project: signature length");
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := calldataload(sig.offset) s := calldataload(add(sig.offset, 32)) v := byte(0, calldataload(add(sig.offset, 64))) }
        require((v == 27 || v == 28) && uint256(s) <= 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0, "Project: signature");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Project: bad signature");
        return signer;
    }
}

/// Variant for project tokens without a burn() function: the paid tokens go straight from the buyer to the
/// canonical dead address (never held by this contract) and the exact transfer is verified before credits mint.
contract ProjectTokenBurnAddressPurchase {
    using SafeTransfer for address;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(uint256 chainId,address projectToken,address creditToken,address buyer,uint256 projectAmount,uint256 baseCredits,uint256 deadline,uint256 nonce)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    ERC20 public immutable projectToken;
    LLMCredit public immutable credit;
    address public immutable owner;
    mapping(uint256 => bool) public usedNonce;
    event ProjectPurchase(address indexed buyer, uint256 projectAmount, uint256 baseCredits, uint256 bonusCredits);
    constructor(ERC20 projectToken_, LLMCredit credit_, address owner_) {
        require(address(projectToken_) != address(0) && address(credit_) != address(0) && owner_ != address(0), "Burn: zero");
        projectToken = projectToken_; credit = credit_; owner = owner_;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Accred Project Burn Purchase"), keccak256("1"), block.chainid, address(this)
        ));
    }
    struct Quote {
        uint256 chainId; address projectToken; address creditToken; address buyer;
        uint256 projectAmount; uint256 baseCredits; uint256 deadline; uint256 nonce;
    }
    function purchase(Quote calldata q, bytes calldata signature) external {
        require(q.chainId == block.chainid && q.projectToken == address(projectToken) && q.creditToken == address(credit), "Burn: domain");
        require(q.buyer == msg.sender && q.projectAmount > 0 && q.baseCredits > 0, "Burn: buyer");
        require(block.timestamp <= q.deadline && !usedNonce[q.nonce], "Burn: quote");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(
            QUOTE_TYPEHASH, q.chainId, q.projectToken, q.creditToken, q.buyer, q.projectAmount, q.baseCredits, q.deadline, q.nonce
        ))));
        require(_recover(digest, signature) == owner, "Burn: signature");
        usedNonce[q.nonce] = true;
        uint256 buyerBefore = projectToken.balanceOf(msg.sender);
        uint256 deadBefore = projectToken.balanceOf(BURN_ADDRESS);
        address(projectToken).transferFrom(msg.sender, BURN_ADDRESS, q.projectAmount);
        require(buyerBefore - projectToken.balanceOf(msg.sender) == q.projectAmount, "Burn: buyer debit");
        require(projectToken.balanceOf(BURN_ADDRESS) - deadBefore == q.projectAmount, "Burn: dead address receipt");
        uint256 bonus = q.baseCredits / 10;
        credit.mint(msg.sender, q.baseCredits + bonus);
        emit ProjectPurchase(msg.sender, q.projectAmount, q.baseCredits, bonus);
    }
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "Burn: signature length");
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := calldataload(sig.offset) s := calldataload(add(sig.offset, 32)) v := byte(0, calldataload(add(sig.offset, 64))) }
        require((v == 27 || v == 28) && uint256(s) <= 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0, "Burn: signature");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Burn: bad signature");
        return signer;
    }
}

/// @notice Locks a user's LLMCredit. No rewards live in this contract: after the lock the user claims the
/// principal here, and the backend pays the USDG reward wallet-to-wallet from the cashback payout wallet.
/// @dev `payout` is the USDG reward in 6-decimal micros (100 credits = $1), recorded for the backend to read.
contract CreditStaking {
    using SafeTransfer for address;
    LLMCredit public immutable credit;
    address public immutable owner;
    uint256 public nextStakeId;
    struct Stake { address user; uint256 amount; uint256 payout; uint256 unlockAt; bool claimed; }
    mapping(uint256 => Stake) public stakes;
    event Staked(uint256 indexed id, address indexed user, uint256 credits, uint256 payout, uint256 unlockAt, uint256 daysLocked);
    event Claimed(uint256 indexed id, address indexed user, uint256 credits, uint256 payout);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    constructor(LLMCredit c, address owner_) {
        require(address(c) != address(0) && owner_ != address(0), "Stake: invalid");
        credit = c; owner = owner_;
    }
    function stake(uint256 credits, uint256 daysLocked) external returns (uint256 id) {
        require(credits > 0, "Stake: zero");
        uint256 bps;
        if (daysLocked == 3) bps = 350; else if (daysLocked == 7) bps = 500; else if (daysLocked == 30) bps = 999; else revert("Stake: term");
        uint256 unit = 10 ** uint256(credit.decimals());
        uint256 payout = FullMath.mulDiv(FullMath.mulDiv(credits, bps, 10000), 10 ** 6, 100 * unit);
        address(credit).transferFrom(msg.sender, address(this), credits);
        id = nextStakeId++;
        stakes[id] = Stake(msg.sender, credits, payout, block.timestamp + daysLocked * 1 days, false);
        emit Staked(id, msg.sender, credits, payout, block.timestamp + daysLocked * 1 days, daysLocked);
    }
    function claim(uint256 id) external {
        Stake storage s = stakes[id];
        require(s.user == msg.sender && !s.claimed, "Stake: unauthorized");
        require(block.timestamp >= s.unlockAt, "Stake: locked");
        s.claimed = true;
        address(credit).transfer(msg.sender, s.amount);
        emit Claimed(id, msg.sender, s.amount, s.payout);
    }
    /// @notice Owner-only recovery for any token mistakenly or emergently held here.
    function emergencyWithdraw(address token, address to, uint256 amount) external {
        require(msg.sender == owner && to != address(0), "Stake: owner");
        token.transfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }
}

/// @notice User-owned credits held against global, gateway-authorized API requests.
/// @dev The LLMCredit owner must explicitly authorize this vault as a burner.
/// @dev All amounts are LLMCredit ERC-20 base units (18 decimals); no conversion is applied.
contract LLMCreditVault {
    using SafeTransfer for address;
    LLMCredit public immutable credit;
    address public owner;
    address public gateway;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public reserved;
    enum ReservationStatus { None, Reserved, Settled, Released }
    struct Reservation { address account; uint256 amount; ReservationStatus status; }
    mapping(bytes32 => Reservation) private _reservations;
    uint256 private _entered;

    event GatewayUpdated(address indexed previousGateway, address indexed newGateway);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Reserved(address indexed account, bytes32 indexed requestId, uint256 amount);
    event Settled(address indexed account, bytes32 indexed requestId, uint256 actualAmount, uint256 releasedAmount);
    event Released(address indexed account, bytes32 indexed requestId, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "Vault: owner"); _; }
    modifier onlyGateway() { require(msg.sender == gateway, "Vault: gateway"); _; }
    modifier nonReentrant() { require(_entered == 0, "Vault: reentrant"); _entered = 1; _; _entered = 0; }

    constructor(LLMCredit c, address initialGateway) {
        require(address(c) != address(0) && initialGateway != address(0), "Vault: zero");
        credit = c;
        owner = msg.sender;
        gateway = initialGateway;
    }

    function available(address account) public view returns (uint256) {
        return deposited[account] - reserved[account];
    }

    /// @notice Returns account, original reserved amount and status (0 none, 1 active, 2 settled, 3 released).
    function reservation(bytes32 requestId) external view returns (address account, uint256 amount, uint8 status) {
        Reservation storage r = _reservations[requestId];
        return (r.account, r.amount, uint8(r.status));
    }

    function setGateway(address newGateway) external onlyOwner {
        require(newGateway != address(0), "Vault: zero gateway");
        emit GatewayUpdated(gateway, newGateway);
        gateway = newGateway;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Vault: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Vault: zero");
        uint256 beforeBalance = credit.balanceOf(address(this));
        address(credit).transferFrom(msg.sender, address(this), amount);
        require(credit.balanceOf(address(this)) == beforeBalance + amount, "Vault: short receipt");
        deposited[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0 && available(msg.sender) >= amount, "Vault: unavailable");
        uint256 vaultBefore = credit.balanceOf(address(this));
        uint256 accountBefore = credit.balanceOf(msg.sender);
        deposited[msg.sender] -= amount;
        address(credit).transfer(msg.sender, amount);
        require(credit.balanceOf(address(this)) == vaultBefore - amount, "Vault: short transfer");
        require(credit.balanceOf(msg.sender) == accountBefore + amount, "Vault: short receipt");
        emit Withdrawn(msg.sender, amount);
    }

    function reserve(address account, bytes32 requestId, uint256 amount) external onlyGateway nonReentrant {
        require(account != address(0) && requestId != bytes32(0) && amount > 0, "Vault: invalid reservation");
        require(_reservations[requestId].status == ReservationStatus.None, "Vault: request used");
        require(available(account) >= amount, "Vault: insufficient available");
        _reservations[requestId] = Reservation(account, amount, ReservationStatus.Reserved);
        reserved[account] += amount;
        emit Reserved(account, requestId, amount);
    }

    /// @notice Burns actual usage in 18-decimal token base units; API microcredits convert by multiplying by 1e12.
    /// @dev Zero actual usage is valid: it terminally closes the request and releases the full hold without burning.
    function settle(bytes32 requestId, uint256 actualAmount) external onlyGateway nonReentrant {
        Reservation storage r = _reservations[requestId];
        require(r.status == ReservationStatus.Reserved, "Vault: inactive request");
        require(actualAmount <= r.amount, "Vault: exceeds reservation");

        address account = r.account;
        uint256 originalAmount = r.amount;
        r.status = ReservationStatus.Settled;
        reserved[account] -= originalAmount;
        deposited[account] -= actualAmount;

        if (actualAmount > 0) {
            uint256 balanceBefore = credit.balanceOf(address(this));
            uint256 supplyBefore = credit.totalSupply();
            credit.burn(actualAmount);
            require(balanceBefore >= actualAmount && credit.balanceOf(address(this)) == balanceBefore - actualAmount, "Vault: burn balance");
            require(supplyBefore >= actualAmount && credit.totalSupply() == supplyBefore - actualAmount, "Vault: burn supply");
        }

        emit Settled(account, requestId, actualAmount, originalAmount - actualAmount);
    }

    function release(bytes32 requestId) external onlyGateway nonReentrant {
        Reservation storage r = _reservations[requestId];
        require(r.status == ReservationStatus.Reserved, "Vault: inactive request");
        address account = r.account;
        uint256 amount = r.amount;
        r.status = ReservationStatus.Released;
        reserved[account] -= amount;
        emit Released(account, requestId, amount);
    }
}

/// @notice Funded USDG cashback for completed crypto-to-credit purchases only.
/// @dev The trusted signer may quote a random rate from 2% through 5%; rate,
/// purchase and user are all bound by EIP-712 and checked against on-chain receipts.
contract CashbackClaimVault {
    using SafeTransfer for address;
    uint256 public constant WINDOW = 60 minutes;
    uint256 public constant MAX_USDG = 10;
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(uint256 chainId,address vault,address user,uint256 purchaseNonce,uint256 baseAmount,uint256 rateBps,uint256 nonce,uint256 deadline)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    ERC20 public immutable usdg;
    uint8 public immutable usdgDecimals;
    address public immutable owner;
    address public immutable claimSigner;
    TreasuryCreditPurchase public immutable purchase;
    mapping(uint256 => bool) public usedNonce;
    mapping(bytes32 => bool) public usedEconomicAction;
    uint256 private _entered;

    struct Claim {
        uint256 chainId;
        address vault;
        address user;
        uint256 purchaseNonce;
        uint256 baseAmount;
        uint256 rateBps;
        uint256 nonce;
        uint256 deadline;
    }
    struct WindowState {
        uint256 head;
        uint256 tail;
        uint256 total;
        uint256 cooldownUntil;
    }
    struct Entry { uint256 timestamp; uint256 amount; }
    mapping(address => WindowState) public windows;
    mapping(address => mapping(uint256 => Entry)) private entries;

    event Funded(address indexed funder, uint256 amount);
    event Claimed(address indexed user, uint256 amount, uint256 rateBps, uint256 purchaseNonce, bytes32 indexed economicActionId, uint256 nonce);

    modifier nonReentrant() { require(_entered == 0, "Cashback: reentrant"); _entered = 1; _; _entered = 0; }

    constructor(ERC20 token, uint8 decimals_, address owner_, address signer_, TreasuryCreditPurchase purchase_) {
        require(address(token) != address(0) && owner_ != address(0) && signer_ != address(0) && address(purchase_) != address(0) && decimals_ <= 18, "Cashback: invalid");
        require(token.decimals() == decimals_, "Cashback: decimal mismatch");
        usdg = token; usdgDecimals = decimals_; owner = owner_; claimSigner = signer_; purchase = purchase_;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Accred Cashback"), keccak256("1"), block.chainid, address(this)
        ));
    }
    function fund(uint256 amount) external nonReentrant {
        require(msg.sender == owner, "Cashback: owner");
        uint256 beforeBalance = usdg.balanceOf(address(this));
        usdg.transferFrom(msg.sender, address(this), amount);
        require(usdg.balanceOf(address(this)) - beforeBalance == amount, "Cashback: short funding");
        emit Funded(msg.sender, amount);
    }
    /// @notice Bounded maintenance for accounts with many expired entries.
    function prune(address user, uint256 maxEntries) external nonReentrant returns (uint256 removed) {
        require(maxEntries > 0 && maxEntries <= 256, "Cashback: prune bound");
        removed = _prune(user, maxEntries);
    }
    function claim(Claim calldata c, bytes calldata signature) external nonReentrant {
        (bytes32 economicActionId, uint256 amount) = _validateClaim(c, signature);
        _executeClaim(c, economicActionId, amount);
    }
    function _validateClaim(Claim calldata c, bytes calldata signature) private view returns (bytes32 economicActionId, uint256 amount) {
        require(block.timestamp <= c.deadline, "Cashback: expired");
        require(c.chainId == block.chainid && c.vault == address(this), "Cashback: domain");
        require(c.user == msg.sender && c.baseAmount > 0 && c.rateBps >= 200 && c.rateBps <= 500, "Cashback: authorization");
        require(!usedNonce[c.nonce], "Cashback: nonce used");
        (address buyer,, uint256 inputAmount, uint256 creditAmount) = purchase.receipts(c.purchaseNonce);
        require(buyer == msg.sender && inputAmount > 0 && creditAmount > 0, "Cashback: no qualifying swap");
        economicActionId = keccak256(abi.encode(address(purchase), c.purchaseNonce));
        require(!usedEconomicAction[economicActionId], "Cashback: action used");
        amount = FullMath.mulDiv(c.baseAmount, c.rateBps, 10000);
        require(amount > 0, "Cashback: zero payout");
        require(_recoverClaim(c, signature) == claimSigner, "Cashback: signature");
    }

    function _executeClaim(Claim calldata c, bytes32 economicActionId, uint256 amount) private {
        _checkAndRecordWindow(c.user, amount);
        usedNonce[c.nonce] = true;
        usedEconomicAction[economicActionId] = true;
        uint256 beforeBalance = usdg.balanceOf(c.user);
        address(usdg).transfer(c.user, amount);
        require(usdg.balanceOf(c.user) - beforeBalance == amount, "Cashback: short receipt");
        emit Claimed(c.user, amount, c.rateBps, c.purchaseNonce, economicActionId, c.nonce);
    }

    function _checkAndRecordWindow(address user, uint256 amount) private {
        WindowState storage w = windows[user];
        require(block.timestamp >= w.cooldownUntil, "Cashback: cooldown");
        uint256 cap = MAX_USDG * 10 ** uint256(usdgDecimals);
        uint256 cutoff = block.timestamp - WINDOW;
        _prune(user, 32);
        if (w.head < w.tail && entries[user][w.head].timestamp <= cutoff && amount > cap - w.total) {
            revert("Cashback: maintenance required");
        }
        require(amount <= cap - w.total, "Cashback: cap");
        require(usdg.balanceOf(address(this)) >= amount, "Cashback: unfunded");
        uint256 tail = w.tail;
        entries[user][tail] = Entry(block.timestamp, amount);
        w.tail = tail + 1;
        w.total += amount;
        if (w.total == cap) w.cooldownUntil = block.timestamp + WINDOW;
    }
    function _prune(address user, uint256 maxEntries) internal returns (uint256 removed) {
        WindowState storage w = windows[user];
        uint256 cutoff = block.timestamp - WINDOW;
        while (w.head < w.tail && removed < maxEntries) {
            Entry storage oldest = entries[user][w.head];
            if (oldest.timestamp > cutoff) break;
            w.total -= oldest.amount;
            delete entries[user][w.head];
            removed++;
            w.head++;
        }
    }
    function _recoverClaim(Claim calldata c, bytes calldata sig) private view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            CLAIM_TYPEHASH, c.chainId, c.vault, c.user, c.purchaseNonce, c.baseAmount, c.rateBps, c.nonce, c.deadline
        ));
        return _recover(keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)), sig);
    }
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "Cashback: signature length");
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := calldataload(sig.offset) s := calldataload(add(sig.offset, 32)) v := byte(0, calldataload(add(sig.offset, 64))) }
        require((v == 27 || v == 28) && uint256(s) <= 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0, "Cashback: signature");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Cashback: bad signature");
        return signer;
    }
}

/// @notice Mints credit only for a verifier-signed attestation of a paid Solana
/// transaction. Solana payment verification and finality belong to the signer;
/// this contract supplies EVM-domain and payment/quote replay protection.
contract SolanaCreditSettlement {
    bytes32 public constant PAID_QUOTE_TYPEHASH = keccak256(
        "PaidQuote(uint256 chainId,address creditToken,address recipient,bytes32 quoteId,bytes32 paymentId,bytes32 sourcePayer,bytes32 assetId,uint256 paidAmount,uint256 creditAmount,uint256 deadline)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    LLMCredit public immutable credit;
    address public immutable paymentVerifier;
    mapping(bytes32 => bool) public usedQuoteId;
    mapping(bytes32 => bool) public usedPaymentId;
    uint256 private _entered;

    struct PaidQuote {
        uint256 chainId;
        address creditToken;
        address recipient;
        bytes32 quoteId;
        bytes32 paymentId;
        bytes32 sourcePayer;
        bytes32 assetId;
        uint256 paidAmount;
        uint256 creditAmount;
        uint256 deadline;
    }

    event PaidSettlement(
        address indexed recipient,
        bytes32 indexed quoteId,
        bytes32 indexed paymentId,
        bytes32 sourcePayer,
        bytes32 assetId,
        uint256 paidAmount,
        uint256 creditAmount
    );

    modifier nonReentrant() { require(_entered == 0, "SolanaSettlement: reentrant"); _entered = 1; _; _entered = 0; }

    constructor(LLMCredit credit_, address verifier_) {
        require(address(credit_) != address(0) && verifier_ != address(0), "SolanaSettlement: zero");
        credit = credit_;
        paymentVerifier = verifier_;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Accred Solana Paid Settlement"), keccak256("1"), block.chainid, address(this)
        ));
    }

    function settle(PaidQuote calldata q, bytes calldata signature) external nonReentrant {
        require(block.timestamp <= q.deadline, "SolanaSettlement: expired");
        require(q.chainId == block.chainid && q.creditToken == address(credit), "SolanaSettlement: domain");
        require(q.recipient != address(0) && q.quoteId != bytes32(0) && q.paymentId != bytes32(0), "SolanaSettlement: identifiers");
        require(q.sourcePayer != bytes32(0) && q.assetId != bytes32(0) && q.paidAmount > 0 && q.creditAmount > 0, "SolanaSettlement: payment");
        require(!usedQuoteId[q.quoteId] && !usedPaymentId[q.paymentId], "SolanaSettlement: replay");

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(
            PAID_QUOTE_TYPEHASH,
            q.chainId,
            q.creditToken,
            q.recipient,
            q.quoteId,
            q.paymentId,
            q.sourcePayer,
            q.assetId,
            q.paidAmount,
            q.creditAmount,
            q.deadline
        ))));
        require(_recover(digest, signature) == paymentVerifier, "SolanaSettlement: signature");

        usedQuoteId[q.quoteId] = true;
        usedPaymentId[q.paymentId] = true;
        credit.mint(q.recipient, q.creditAmount);
        emit PaidSettlement(q.recipient, q.quoteId, q.paymentId, q.sourcePayer, q.assetId, q.paidAmount, q.creditAmount);
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "SolanaSettlement: signature length");
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := calldataload(sig.offset) s := calldataload(add(sig.offset, 32)) v := byte(0, calldataload(add(sig.offset, 64))) }
        require((v == 27 || v == 28) && uint256(s) <= 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0, "SolanaSettlement: signature");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "SolanaSettlement: bad signer");
        return signer;
    }
}

/// @notice Redeems wallet-held LLMCredit for owner-funded six-decimal USDG.
/// @dev This contract does not read or withdraw LLMCreditVault deposits; users
/// must withdraw any unreserved API credits separately before redeeming them.
contract LLMCreditRedeemer {
    using SafeTransfer for address;

    bytes32 public constant REDEEM_QUOTE_TYPEHASH = keccak256(
        "RedeemQuote(uint256 chainId,address redeemer,address creditToken,address usdgToken,address wallet,uint256 creditAmount,uint256 usdgAmount,uint256 deadline,bytes32 quoteId,bytes32 actionId)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;
    LLMCredit public immutable credit;
    ERC20 public immutable usdg;
    address public owner;
    address public quoteSigner;
    mapping(bytes32 => bool) public usedQuoteId;
    mapping(bytes32 => bool) public usedActionId;
    uint256 private _entered;
    struct RedeemQuoteData {
        uint256 chainId;
        address redeemer;
        address creditToken;
        address usdgToken;
        address wallet;
        uint256 creditAmount;
        uint256 usdgAmount;
        uint256 deadline;
        bytes32 quoteId;
        bytes32 actionId;
    }

    event Funded(address indexed funder, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    event QuoteSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Redeemed(
        address indexed wallet,
        bytes32 indexed quoteId,
        bytes32 indexed actionId,
        uint256 creditAmount,
        uint256 usdgAmount
    );

    modifier onlyOwner() { require(msg.sender == owner, "Redeemer: owner"); _; }
    modifier nonReentrant() { require(_entered == 0, "Redeemer: reentrant"); _entered = 1; _; _entered = 0; }

    constructor(LLMCredit credit_, ERC20 usdg_, address quoteSigner_) {
        require(address(credit_) != address(0) && address(usdg_) != address(0), "Redeemer: zero token");
        require(address(credit_) != address(usdg_) && quoteSigner_ != address(0), "Redeemer: invalid");
        require(credit_.decimals() == 18 && usdg_.decimals() == 6, "Redeemer: decimals");
        credit = credit_;
        usdg = usdg_;
        owner = msg.sender;
        quoteSigner = quoteSigner_;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Accred Credit Redeemer"), keccak256("1"), block.chainid, address(this)
        ));
    }

    /// @notice Entire balance is available: redemptions are atomic, with no off-chain reserved payouts.
    function availableReserve() public view returns (uint256) {
        return usdg.balanceOf(address(this));
    }

    function setQuoteSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "Redeemer: zero signer");
        emit QuoteSignerUpdated(quoteSigner, newSigner);
        quoteSigner = newSigner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Redeemer: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function fund(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Redeemer: zero funding");
        uint256 ownerBefore = usdg.balanceOf(msg.sender);
        uint256 reserveBefore = usdg.balanceOf(address(this));
        address(usdg).transferFrom(msg.sender, address(this), amount);
        require(ownerBefore >= amount && usdg.balanceOf(msg.sender) == ownerBefore - amount, "Redeemer: funding debit");
        require(usdg.balanceOf(address(this)) == reserveBefore + amount, "Redeemer: short funding");
        emit Funded(msg.sender, amount);
    }

    /// @notice Owner may withdraw only currently-held USDG; no redemption payment is reserved off-chain.
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0 && amount <= availableReserve(), "Redeemer: reserve unavailable");
        uint256 reserveBefore = usdg.balanceOf(address(this));
        uint256 ownerBefore = usdg.balanceOf(owner);
        address(usdg).transfer(owner, amount);
        require(usdg.balanceOf(address(this)) == reserveBefore - amount, "Redeemer: short withdrawal");
        require(usdg.balanceOf(owner) == ownerBefore + amount, "Redeemer: short owner receipt");
        emit Withdrawn(owner, amount);
    }

    /// @notice Redeem wallet-held credits using a quote signed for this chain,
    /// this contract, the calling wallet, both token addresses, amounts and IDs.
    /// @dev creditAmount uses 18-decimal LLMCredit units; usdgAmount uses 6-decimal USDG units.
    function redeem(
        bytes32 quoteId,
        bytes32 actionId,
        uint256 creditAmount,
        uint256 usdgAmount,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        require(block.timestamp <= deadline, "Redeemer: expired");
        require(quoteId != bytes32(0) && actionId != bytes32(0), "Redeemer: zero identifier");
        require(creditAmount > 0 && usdgAmount > 0, "Redeemer: zero amount");
        require(!usedQuoteId[quoteId] && !usedActionId[actionId], "Redeemer: replay");
        require(availableReserve() >= usdgAmount, "Redeemer: unfunded");

        require(_recover(_redeemDigest(quoteId, actionId, creditAmount, usdgAmount, deadline, msg.sender), signature) == quoteSigner, "Redeemer: signature");

        usedQuoteId[quoteId] = true;
        usedActionId[actionId] = true;

        uint256 walletCreditBefore = credit.balanceOf(msg.sender);
        uint256 redeemerCreditBefore = credit.balanceOf(address(this));
        address(credit).transferFrom(msg.sender, address(this), creditAmount);
        require(redeemerCreditBefore + creditAmount == credit.balanceOf(address(this)), "Redeemer: short credit receipt");
        require(walletCreditBefore >= creditAmount && credit.balanceOf(msg.sender) == walletCreditBefore - creditAmount, "Redeemer: unexpected credit debit");

        uint256 supplyBefore = credit.totalSupply();
        uint256 balanceBeforeBurn = credit.balanceOf(address(this));
        credit.burn(creditAmount);
        require(balanceBeforeBurn >= creditAmount && credit.balanceOf(address(this)) == balanceBeforeBurn - creditAmount, "Redeemer: burn balance");
        require(supplyBefore >= creditAmount && credit.totalSupply() == supplyBefore - creditAmount, "Redeemer: burn supply");

        uint256 reserveBefore = usdg.balanceOf(address(this));
        uint256 walletUsdgBefore = usdg.balanceOf(msg.sender);
        address(usdg).transfer(msg.sender, usdgAmount);
        require(reserveBefore >= usdgAmount && usdg.balanceOf(address(this)) == reserveBefore - usdgAmount, "Redeemer: reserve debit");
        require(usdg.balanceOf(msg.sender) == walletUsdgBefore + usdgAmount, "Redeemer: short USDG receipt");

        emit Redeemed(msg.sender, quoteId, actionId, creditAmount, usdgAmount);
    }

    function _redeemDigest(
        bytes32 quoteId,
        bytes32 actionId,
        uint256 creditAmount,
        uint256 usdgAmount,
        uint256 deadline,
        address wallet
    ) private view returns (bytes32) {
        RedeemQuoteData memory q;
        q.chainId = block.chainid;
        q.redeemer = address(this);
        q.creditToken = address(credit);
        q.usdgToken = address(usdg);
        q.wallet = wallet;
        q.creditAmount = creditAmount;
        q.usdgAmount = usdgAmount;
        q.deadline = deadline;
        q.quoteId = quoteId;
        q.actionId = actionId;
        bytes32 typeHash = REDEEM_QUOTE_TYPEHASH;
        bytes32 structHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            for { let offset := 0 } lt(offset, 320) { offset := add(offset, 32) } {
                mstore(add(ptr, add(offset, 32)), mload(add(q, offset)))
            }
            structHash := keccak256(ptr, 352)
            mstore(0x40, add(ptr, 352))
        }
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "Redeemer: signature length");
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := calldataload(sig.offset) s := calldataload(add(sig.offset, 32)) v := byte(0, calldataload(add(sig.offset, 64))) }
        require((v == 27 || v == 28) && uint256(s) <= 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0, "Redeemer: signature");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Redeemer: bad signer");
        return signer;
    }
}

/// @dev Local adversarial fixture for USDG funding and payout receipt checks.
contract MockVaultAdversarialUSDG {
    string public constant name = "Adversarial USDG";
    string public constant symbol = "BADUSDG";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public noOpTransferFrom = true;
    bool public noOpTransfer = true;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function setNoOpTransferFrom(bool enabled) external { noOpTransferFrom = enabled; }
    function setNoOpTransfer(bool enabled) external { noOpTransfer = enabled; }
    function transfer(address to, uint256 amount) external returns (bool) {
        if (noOpTransfer) return true;
        require(balanceOf[msg.sender] >= amount, "BadUSDG: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (noOpTransferFrom) return true;
        uint256 permitted = allowance[from][msg.sender];
        require(permitted >= amount && balanceOf[from] >= amount, "BadUSDG: allowance");
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}