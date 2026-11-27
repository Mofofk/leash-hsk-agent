// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolOracle} from "./lib/PoolOracle.sol";
import {IERC20Min, IUniswapV3PoolLike} from "./interfaces/IHSKSwap.sol";

/// @title LeashLend
/// @notice Minimal single-market lending pool for the Leash demo on HSK Chain TESTNET.
///         Deposit WHSK as collateral, borrow USDT up to `LTV_BPS` of its value, repay, withdraw.
///         Positions whose debt exceeds `LIQ_THRESHOLD_BPS` of collateral value (health factor < 1)
///         can be liquidated by anyone for a `LIQ_BONUS_BPS` bonus in collateral.
///         Collateral is priced at the HSKSwap WHSK/USDT pool TWAP (observe()), the same oracle code
///         LeashVault uses, with two sanity bounds: spot must sit within `MAX_DEVIATION_TICKS` of the TWAP,
///         and the TWAP price must sit inside an immutable [minPrice, maxPrice] band.
///         Fixed borrow APR accrues per second through a global borrow index.
/// @dev UNAUDITED. Built for a hackathon demo on testnet tokens only.
contract LeashLend {
    // ----------------------------------------------------------------------------- parameters
    uint256 public constant LTV_BPS = 5_000; // max borrow = 50% of collateral value
    uint256 public constant LIQ_THRESHOLD_BPS = 6_500; // liquidatable when debt > 65% of collateral value
    uint256 public constant LIQ_BONUS_BPS = 500; // liquidator receives 5% extra collateral
    uint256 public constant APR_BPS = 500; // 5% fixed borrow APR, simple per second, compounded on accrual
    uint32 public constant TWAP_WINDOW = 300; // seconds
    int24 public constant MAX_DEVIATION_TICKS = 500; // |spot - TWAP| <= ~5%
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    IERC20Min public immutable collateral; // WHSK
    IERC20Min public immutable debtAsset; // USDT
    address public immutable pool; // HSKSwap WHSK/USDT pool
    uint256 public immutable minPrice; // USDT units per 1e18 WHSK units
    uint256 public immutable maxPrice;

    address public owner;
    bool public paused;

    // ----------------------------------------------------------------------------- state
    uint256 public borrowIndex = WAD; // debt per scaled unit
    uint64 public lastAccrual;
    uint256 public totalScaledDebt;
    uint256 public totalCollateral;

    struct Account {
        uint256 collateral; // WHSK units
        uint256 scaledDebt; // debt / borrowIndex
    }

    mapping(address => Account) public accounts;

    uint256 private _lock = 1;

    // ----------------------------------------------------------------------------- events
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed payer, address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, uint256 repaid, uint256 seized);
    event Funded(address indexed from, uint256 amount);
    event LiquidityWithdrawn(address indexed to, uint256 amount);
    event Paused(bool paused);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error IsPaused();
    error ZeroAmount();
    error Unhealthy();
    error ExceedsLtv();
    error NoLiquidity();
    error Healthy();
    error PriceOutOfBounds();
    error SpotDeviates();
    error OracleUnavailable();
    error TransferFailed();
    error Reentrancy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address owner_, address collateral_, address debtAsset_, address pool_, uint256 minPrice_, uint256 maxPrice_) {
        require(owner_ != address(0) && pool_ != address(0), "zero");
        require(minPrice_ > 0 && maxPrice_ > minPrice_, "band");
        address t0 = IUniswapV3PoolLike(pool_).token0();
        address t1 = IUniswapV3PoolLike(pool_).token1();
        require((t0 == collateral_ && t1 == debtAsset_) || (t0 == debtAsset_ && t1 == collateral_), "pool");
        owner = owner_;
        collateral = IERC20Min(collateral_);
        debtAsset = IERC20Min(debtAsset_);
        pool = pool_;
        minPrice = minPrice_;
        maxPrice = maxPrice_;
        lastAccrual = uint64(block.timestamp);
        emit OwnershipTransferred(address(0), owner_);
    }

    // ============================================================================= user actions
    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _pull(collateral, msg.sender, amount);
        accounts[msg.sender].collateral += amount;
        totalCollateral += amount;
        emit Deposit(msg.sender, amount);
    }

    /// @notice Borrow USDT against deposited WHSK. Debt after the borrow must stay within LTV_BPS.
    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _accrue();
        if (amount > cash()) revert NoLiquidity();
        Account storage a = accounts[msg.sender];
        uint256 newDebt = _debt(a) + amount;
        if (newDebt * 10_000 > _value(a.collateral, true) * LTV_BPS) revert ExceedsLtv();
        uint256 scaled = _divUp(amount * WAD, borrowIndex);
        a.scaledDebt += scaled;
        totalScaledDebt += scaled;
        _push(debtAsset, msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    /// @notice Repay your own debt. `type(uint256).max` repays everything. Works while paused.
    function repay(uint256 amount) external nonReentrant returns (uint256 paid) {
        return _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repay someone else's debt (no reward). Works while paused.
    function repayFor(address user, uint256 amount) external nonReentrant returns (uint256 paid) {
        return _repay(msg.sender, user, amount);
    }

    /// @notice Withdraw collateral. Remaining debt must stay within LTV_BPS of the remaining collateral.
    ///         Allowed while paused (users can always exit a healthy position).
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue();
        Account storage a = accounts[msg.sender];
        require(amount <= a.collateral, "collateral");
        uint256 left = a.collateral - amount;
        uint256 d = _debt(a);
        if (d > 0 && d * 10_000 > _value(left, true) * LTV_BPS) revert Unhealthy();
        a.collateral = left;
        totalCollateral -= amount;
        _push(collateral, msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Repay up to `repayAmount` of an unhealthy position (health factor < 1) and seize
    ///         collateral worth the repaid amount plus LIQ_BONUS_BPS, at the TWAP. Partial closes allowed.
    function liquidate(address user, uint256 repayAmount) external nonReentrant returns (uint256 repaid, uint256 seized) {
        if (repayAmount == 0) revert ZeroAmount();
        _accrue();
        Account storage a = accounts[user];
        uint256 d = _debt(a);
        uint256 px = _price(true);
        uint256 val = a.collateral * px / WAD;
        if (d == 0 || d * 10_000 <= val * LIQ_THRESHOLD_BPS) revert Healthy();
        repaid = repayAmount > d ? d : repayAmount;
        seized = repaid * (10_000 + LIQ_BONUS_BPS) / 10_000 * WAD / px;
        if (seized > a.collateral) {
            // underwater: take all collateral, charge the liquidator proportionally less
            seized = a.collateral;
            repaid = seized * px / WAD * 10_000 / (10_000 + LIQ_BONUS_BPS);
            if (repaid > d) repaid = d;
        }
        if (repaid == 0) revert ZeroAmount();
        _pull(debtAsset, msg.sender, repaid);
        _reduceDebt(a, repaid, d);
        a.collateral -= seized;
        totalCollateral -= seized;
        _push(collateral, msg.sender, seized);
        emit Liquidate(msg.sender, user, repaid, seized);
    }

    // ============================================================================= owner
    /// @notice Add USDT liquidity (anyone may fund; it is a donation to the pool).
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _pull(debtAsset, msg.sender, amount);
        emit Funded(msg.sender, amount);
    }

    function withdrawLiquidity(uint256 amount, address to) external onlyOwner nonReentrant {
        if (amount > cash()) revert NoLiquidity();
        _push(debtAsset, to, amount);
        emit LiquidityWithdrawn(to, amount);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    function transferOwnership(address n) external onlyOwner {
        require(n != address(0), "zero");
        emit OwnershipTransferred(owner, n);
        owner = n;
    }

    // ============================================================================= views
    /// @notice USDT available to borrow / withdraw.
    function cash() public view returns (uint256) {
        return debtAsset.balanceOf(address(this));
    }

    function currentBorrowIndex() public view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return borrowIndex;
        return borrowIndex + borrowIndex * APR_BPS * dt / (10_000 * YEAR);
    }

    function totalDebt() public view returns (uint256) {
        return _mulUp(totalScaledDebt, currentBorrowIndex());
    }

    function debtOf(address user) public view returns (uint256) {
        return _mulUp(accounts[user].scaledDebt, currentBorrowIndex());
    }

    /// @notice TWAP price of 1e18 WHSK units in USDT units, with sanity checks applied.
    function price() external view returns (uint256) {
        return _price(true);
    }

    /// @notice Raw oracle read for dashboards: never reverts.
    function oracle() external view returns (bool ok, uint256 twapPrice, uint256 spotPrice, int24 twapTick, int24 spotTick, bool sane) {
        spotTick = PoolOracle.spotTick(pool);
        spotPrice = PoolOracle.quoteAtTick(spotTick, WAD, address(collateral), address(debtAsset));
        (ok, twapTick) = _tryTwap();
        if (ok) {
            twapPrice = PoolOracle.quoteAtTick(twapTick, WAD, address(collateral), address(debtAsset));
            int24 dev = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
            sane = dev <= MAX_DEVIATION_TICKS && twapPrice >= minPrice && twapPrice <= maxPrice;
        }
    }

    /// @notice Everything a UI needs about one account. healthFactor is 1e18-scaled (max uint when no debt).
    function position(address user)
        external
        view
        returns (uint256 collateralAmt, uint256 debt, uint256 collateralValue, uint256 maxBorrow, uint256 available, uint256 healthFactor)
    {
        Account memory a = accounts[user];
        collateralAmt = a.collateral;
        debt = _mulUp(a.scaledDebt, currentBorrowIndex());
        collateralValue = _value(a.collateral, false);
        maxBorrow = collateralValue * LTV_BPS / 10_000;
        available = maxBorrow > debt ? maxBorrow - debt : 0;
        uint256 c = cash();
        if (available > c) available = c;
        healthFactor = debt == 0 ? type(uint256).max : collateralValue * LIQ_THRESHOLD_BPS / 10_000 * WAD / debt;
    }

    /// @notice Pool-wide stats for dashboards. Never reverts on oracle trouble (price 0, sane false).
    function stats()
        external
        view
        returns (uint256 cash_, uint256 totalDebt_, uint256 totalCollateral_, uint256 twapPrice, uint256 utilizationBps, bool sane, bool paused_)
    {
        cash_ = cash();
        totalDebt_ = totalDebt();
        totalCollateral_ = totalCollateral;
        (bool ok, int24 t) = _tryTwap();
        if (ok) {
            twapPrice = PoolOracle.quoteAtTick(t, WAD, address(collateral), address(debtAsset));
            int24 s = PoolOracle.spotTick(pool);
            int24 dev = s > t ? s - t : t - s;
            sane = dev <= MAX_DEVIATION_TICKS && twapPrice >= minPrice && twapPrice <= maxPrice;
        }
        uint256 supplied = cash_ + totalDebt_;
        utilizationBps = supplied == 0 ? 0 : totalDebt_ * 10_000 / supplied;
        paused_ = paused;
    }

    // ============================================================================= internals
    function _accrue() internal {
        uint256 idx = currentBorrowIndex();
        if (idx != borrowIndex) borrowIndex = idx;
        lastAccrual = uint64(block.timestamp);
    }

    function _debt(Account storage a) internal view returns (uint256) {
        return _mulUp(a.scaledDebt, borrowIndex);
    }

    function _repay(address payer, address user, uint256 amount) internal returns (uint256 paid) {
        if (amount == 0) revert ZeroAmount();
        _accrue();
        Account storage a = accounts[user];
        uint256 d = _debt(a);
        paid = amount > d ? d : amount;
        if (paid == 0) revert ZeroAmount();
        _pull(debtAsset, payer, paid);
        _reduceDebt(a, paid, d);
        emit Repay(payer, user, paid);
    }

    function _reduceDebt(Account storage a, uint256 paid, uint256 d) internal {
        uint256 scaled = paid == d ? a.scaledDebt : paid * WAD / borrowIndex;
        if (scaled > a.scaledDebt) scaled = a.scaledDebt;
        a.scaledDebt -= scaled;
        totalScaledDebt -= scaled;
    }

    /// @dev value of `amount` WHSK in USDT at the checked TWAP price. `strict` reverts on bad oracle;
    ///      non-strict (views) returns 0 instead.
    function _value(uint256 amount, bool strict) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 p = _price(strict);
        return amount * p / WAD;
    }

    function _price(bool strict) internal view returns (uint256 p) {
        (bool ok, int24 t) = _tryTwap();
        if (!ok) {
            if (strict) revert OracleUnavailable();
            return 0;
        }
        p = PoolOracle.quoteAtTick(t, WAD, address(collateral), address(debtAsset));
        int24 s = PoolOracle.spotTick(pool);
        int24 dev = s > t ? s - t : t - s;
        if (dev > MAX_DEVIATION_TICKS) {
            if (strict) revert SpotDeviates();
            return 0;
        }
        if (p < minPrice || p > maxPrice) {
            if (strict) revert PriceOutOfBounds();
            return 0;
        }
    }

    /// @dev same TWAP read as LeashVault._tryTwap, fixed window.
    function _tryTwap() internal view returns (bool ok, int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        try IUniswapV3PoolLike(pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[1] - cum[0];
            int56 ww = int56(uint56(TWAP_WINDOW));
            tick = int24(delta / ww);
            if (delta < 0 && (delta % ww != 0)) tick--;
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _pull(IERC20Min t, address from, uint256 amount) internal {
        (bool s, bytes memory r) = address(t).call(abi.encodeCall(IERC20Min.transferFrom, (from, address(this), amount)));
        if (!s || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }

    function _push(IERC20Min t, address to, uint256 amount) internal {
        (bool s, bytes memory r) = address(t).call(abi.encodeCall(IERC20Min.transfer, (to, amount)));
        if (!s || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }

    function _mulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 p = a * b;
        return p == 0 ? 0 : (p - 1) / WAD + 1;
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
