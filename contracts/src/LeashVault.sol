// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Min, IUniswapV3PoolLike, IUniswapV3FactoryLike, ISwapRouter02, IWETH9Like} from "./interfaces/IHSKSwap.sol";
import {PoolOracle} from "./lib/PoolOracle.sol";

/// @notice Chainlink-compatible price feed (APRO on HSK Chain exposes this interface).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title LeashVault
/// @notice A trading vault for an AI agent on HSKSwap. The user (owner) holds the funds and the rules;
///         the agent can only ask the vault to trade. Every limit is enforced here, on-chain, so no prompt,
///         model error or compromised agent key can move money outside the leash:
///         - allow-listed tokens and pools only, swap output always comes back to the vault
///         - max trade size and max position size (valued at the pool TWAP, not the manipulable spot price)
///         - max slippage vs TWAP, and a spot-vs-TWAP deviation guard against manipulated pools
///         - cooldown between trades and max trades per day (trade frequency)
///         - daily loss circuit breaker (only de-risking trades allowed after it trips)
///         - stop-loss per position that anyone can enforce
///         - kill switch (pause) and agent revocation, owned by the user
///         Rejected requests are not silent reverts: they emit TradeBlocked with a reason code, so every
///         agent decision (executed, blocked, or hold) leaves an auditable on-chain trail with a reason hash.
contract LeashVault {
    // ----------------------------------------------------------------------------------------- types
    struct RiskParams {
        uint128 maxTradeQuote; // max value of one trade, in quote-token units
        uint16 maxPositionBps; // max value of any non-quote position after a buy, as bps of NAV
        uint16 maxSlippageBps; // min output = TWAP-expected output * (1 - this)
        uint16 maxDeviationBps; // max |spot tick - TWAP tick| (1 tick ~ 1 bp) on the traded pool
        uint16 dailyLossBps; // circuit breaker: NAV drop vs start of day that halts risk-on trades
        uint16 stopLossBps; // position value below cost basis by this much => anyone may force a sell
        uint32 cooldown; // min seconds between agent trades
        uint16 maxTradesPerDay; // trade frequency cap
        uint32 twapWindow; // seconds used for TWAP valuation
    }

    enum Block {
        NONE,
        PAUSED,
        TOKEN_NOT_ALLOWED,
        POOL_NOT_ALLOWED,
        INSUFFICIENT_BALANCE,
        COOLDOWN,
        FREQUENCY,
        ORACLE,
        PRICE_DEVIATION,
        TRADE_TOO_LARGE,
        POSITION_LIMIT,
        DAILY_LOSS_LIMIT,
        STOP_LOSS_ACTIVE,
        SLIPPAGE,
        ARB_UNPROFITABLE,
        ORACLE_DEVIATION,
        STABLE_DEPEG
    }

    /// @notice External USD feed used to cross-check the pool TWAP (e.g. APRO HSK/USD on HSK mainnet).
    struct OracleCfg {
        address feed;
        uint32 maxAge; // seconds; older answers block trading
        uint16 maxDevBps; // max |TWAP-implied USD price - feed price|
    }

    struct TradeRequest {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint256 minAmountOut; // agent's own floor; the vault uses max(this, TWAP floor)
        bytes32 reasonHash; // keccak256 of the agent's full JSON reasoning (published off-chain)
        string memo; // short human-readable reason
    }

    struct ArbRequest {
        address tokenA; // start and end token
        address tokenB;
        uint24 feeSell; // pool where A is sold for B
        uint24 feeBuy; // pool where B is sold back for A
        uint256 amountIn;
        uint16 minProfitBps; // the whole round trip reverts unless A grows by at least this much
        bytes32 reasonHash;
        string memo;
    }

    // -------------------------------------------------------------------------------- hard limits
    // Bounds even the owner (or an LLM translating the owner's chat) cannot exceed.
    uint16 public constant HARD_MAX_SLIPPAGE_BPS = 1000; // 10%
    uint16 public constant HARD_MAX_DEVIATION_BPS = 2000; // 20%
    uint16 public constant HARD_MAX_DAILY_LOSS_BPS = 5000; // 50%
    uint16 public constant HARD_MIN_STOP_LOSS_BPS = 50; // 0.5%
    uint16 public constant HARD_MAX_STOP_LOSS_BPS = 5000; // 50%
    uint32 public constant HARD_MIN_TWAP = 60;
    uint32 public constant HARD_MAX_TWAP = 3600;
    uint16 public constant HARD_MAX_TRADES_PER_DAY = 500;

    // ----------------------------------------------------------------------------------- storage
    address public immutable router;
    address public immutable factory;
    address public immutable quoteToken;
    address public immutable wrappedNative;

    address public owner;
    address public agent;
    bool public paused;

    RiskParams public risk;
    /// @notice Loosening a limit is timelocked so a hijacked chat/LLM or owner session cannot instantly
    ///         widen the leash; tightening applies immediately.
    uint32 public immutable loosenDelay;
    RiskParams public pendingRisk;
    uint64 public pendingRiskAt; // 0 = nothing queued

    address[] internal _tokens;
    mapping(address => bool) public allowedToken;
    mapping(address => address) public refPool; // token => pool vs quote used for valuation
    mapping(address => bool) public allowedPool;

    mapping(address => OracleCfg) public oracleOf; // token => USD feed (optional)
    OracleCfg public quoteUsdOracle; // quote token USD feed for the depeg guard; maxDevBps = max depeg
    uint8 public immutable quoteDecimals;

    mapping(address => uint256) public costBasis; // quote units
    int256 public realizedPnl; // quote units
    int256 public netDeposits; // quote units

    uint64 public lastTradeAt;
    uint64 public currentDay;
    uint16 public tradesToday;
    uint256 public dayStartNav;

    uint256 public tradeCount;
    uint256 public blockedCount;
    uint256 public decisionCount;

    uint256 private _lock = 1;

    // ------------------------------------------------------------------------------------ events
    event TradeExecuted(
        uint256 indexed id,
        address indexed tokenIn,
        address indexed tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOut,
        uint256 minAmountOut,
        int256 realizedPnl,
        bytes32 reasonHash,
        string memo
    );
    event TradeBlocked(
        uint256 indexed id,
        Block indexed code,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes32 reasonHash,
        string memo
    );
    event ArbitrageExecuted(
        uint256 indexed id, address tokenA, address tokenB, uint24 feeSell, uint24 feeBuy, uint256 amountIn, uint256 amountOut, bytes32 reasonHash, string memo
    );
    event StopLossTriggered(address indexed token, address indexed caller, uint256 amountIn, uint256 amountOut, int256 realizedPnl);
    event Decision(uint256 indexed id, uint8 indexed kind, bytes32 reasonHash, string memo);
    event RiskParamsUpdated(RiskParams params, bytes32 instructionHash, string instruction);
    event RiskParamsQueued(RiskParams params, uint64 effectiveAt, bytes32 instructionHash, string instruction);
    event PendingRiskCancelled();
    event OracleConfigured(address indexed token, address feed, uint32 maxAge, uint16 maxDevBps);
    event TokenConfigured(address indexed token, address refPool, bool allowed);
    event PoolConfigured(address indexed pool, bool allowed);
    event AgentChanged(address indexed agent);
    event Paused(address indexed by, string reason);
    event Unpaused(address indexed by);
    event Deposited(address indexed token, uint256 amount, uint256 value);
    event Withdrawn(address indexed token, uint256 amount, address to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotAgent();
    error BadParams();
    error Reentrancy();
    error OnlySelf();
    error ArbFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address _owner,
        address _agent,
        address _router,
        address _factory,
        address _quoteToken,
        address _wrappedNative,
        RiskParams memory _risk,
        uint32 _loosenDelay
    ) {
        loosenDelay = _loosenDelay;
        owner = _owner;
        agent = _agent;
        router = _router;
        factory = _factory;
        quoteToken = _quoteToken;
        wrappedNative = _wrappedNative;
        quoteDecimals = IERC20Min(_quoteToken).decimals();
        _setRisk(_risk);
        _tokens.push(_quoteToken);
        allowedToken[_quoteToken] = true;
        emit OwnershipTransferred(address(0), _owner);
        emit AgentChanged(_agent);
        emit TokenConfigured(_quoteToken, address(0), true);
        emit RiskParamsUpdated(_risk, bytes32(0), "genesis");
    }

    receive() external payable {
        require(msg.sender == wrappedNative, "native");
    }

    // ============================================================================ owner controls
    /// @notice Tighter-or-equal limits apply at once. Anything looser is queued for `loosenDelay` seconds.
    function setRiskParams(RiskParams calldata p, string calldata instruction) external onlyOwner {
        _validate(p);
        if (isTighterOrEqual(p, risk) || loosenDelay == 0) {
            risk = p;
            pendingRiskAt = 0;
            emit RiskParamsUpdated(p, keccak256(bytes(instruction)), instruction);
        } else {
            pendingRisk = p;
            pendingRiskAt = uint64(block.timestamp) + loosenDelay;
            emit RiskParamsQueued(p, pendingRiskAt, keccak256(bytes(instruction)), instruction);
        }
    }

    /// @notice Anyone may activate a queued loosening once its delay has passed.
    function applyPendingRisk() external {
        require(pendingRiskAt != 0 && block.timestamp >= pendingRiskAt, "not ready");
        RiskParams memory p = pendingRisk;
        risk = p;
        pendingRiskAt = 0;
        emit RiskParamsUpdated(p, bytes32(0), "timelocked loosening applied");
    }

    function cancelPendingRisk() external onlyOwner {
        pendingRiskAt = 0;
        emit PendingRiskCancelled();
    }

    function isTighterOrEqual(RiskParams memory n, RiskParams memory o) public pure returns (bool) {
        bool stopOk = o.stopLossBps == 0 || (n.stopLossBps != 0 && n.stopLossBps <= o.stopLossBps);
        return n.maxTradeQuote <= o.maxTradeQuote && n.maxPositionBps <= o.maxPositionBps
            && n.maxSlippageBps <= o.maxSlippageBps && n.maxDeviationBps <= o.maxDeviationBps
            && n.dailyLossBps <= o.dailyLossBps && stopOk && n.cooldown >= o.cooldown
            && n.maxTradesPerDay <= o.maxTradesPerDay && n.twapWindow >= o.twapWindow;
    }

    function _setRisk(RiskParams memory p) internal {
        _validate(p);
        risk = p;
    }

    function _validate(RiskParams memory p) internal pure {
        if (
            p.maxSlippageBps > HARD_MAX_SLIPPAGE_BPS || p.maxDeviationBps > HARD_MAX_DEVIATION_BPS
                || p.dailyLossBps > HARD_MAX_DAILY_LOSS_BPS || p.maxPositionBps > 10_000
                || (p.stopLossBps != 0 && (p.stopLossBps < HARD_MIN_STOP_LOSS_BPS || p.stopLossBps > HARD_MAX_STOP_LOSS_BPS))
                || p.twapWindow < HARD_MIN_TWAP || p.twapWindow > HARD_MAX_TWAP || p.maxTradesPerDay > HARD_MAX_TRADES_PER_DAY
        ) revert BadParams();
    }

    /// @param pool the token/quote pool used to value `token` (must be an HSKSwap factory pool).
    function configureToken(address token, address pool, bool allowed) external onlyOwner {
        if (token != quoteToken) {
            if (allowed) {
                address t0 = IUniswapV3PoolLike(pool).token0();
                address t1 = IUniswapV3PoolLike(pool).token1();
                uint24 f = IUniswapV3PoolLike(pool).fee();
                if (!((t0 == token && t1 == quoteToken) || (t1 == token && t0 == quoteToken))) revert BadParams();
                if (IUniswapV3FactoryLike(factory).getPool(t0, t1, f) != pool) revert BadParams();
            }
            if (refPool[token] == address(0)) _tokens.push(token);
            refPool[token] = pool;
        }
        allowedToken[token] = allowed;
        emit TokenConfigured(token, pool, allowed);
    }

    function configurePool(address pool, bool allowed) external onlyOwner {
        if (allowed) {
            address t0 = IUniswapV3PoolLike(pool).token0();
            address t1 = IUniswapV3PoolLike(pool).token1();
            if (IUniswapV3FactoryLike(factory).getPool(t0, t1, IUniswapV3PoolLike(pool).fee()) != pool) revert BadParams();
        }
        allowedPool[pool] = allowed;
        emit PoolConfigured(pool, allowed);
    }

    /// @param token the asset (or the quote token itself for the stablecoin depeg guard); feed 0 disables.
    function setOracle(address token, address feed, uint32 maxAge, uint16 maxDevBps) external onlyOwner {
        if (feed != address(0) && (maxAge == 0 || maxDevBps == 0 || maxDevBps > 5000)) revert BadParams();
        OracleCfg memory c = OracleCfg(feed, maxAge, maxDevBps);
        if (token == quoteToken) quoteUsdOracle = c;
        else oracleOf[token] = c;
        emit OracleConfigured(token, feed, maxAge, maxDevBps);
    }

    function setAgent(address a) external onlyOwner {
        agent = a;
        emit AgentChanged(a);
    }

    function transferOwnership(address n) external onlyOwner {
        emit OwnershipTransferred(owner, n);
        owner = n;
    }

    /// @notice Kill switch. The owner can always pause; the agent may pause itself but never unpause.
    function pause(string calldata reason) external {
        if (msg.sender != owner && msg.sender != agent) revert NotOwner();
        paused = true;
        emit Paused(msg.sender, reason);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function deposit(address token, uint256 amount) external onlyOwner nonReentrant {
        require(allowedToken[token], "token");
        require(IERC20Min(token).transferFrom(msg.sender, address(this), amount), "tf");
        _booksIn(token, amount);
    }

    function depositNative() external payable onlyOwner nonReentrant {
        require(allowedToken[wrappedNative], "token");
        IWETH9Like(wrappedNative).deposit{value: msg.value}();
        _booksIn(wrappedNative, msg.value);
    }

    function _booksIn(address token, uint256 amount) internal {
        uint256 v = valueOf(token, amount);
        if (token != quoteToken) costBasis[token] += v;
        netDeposits += int256(v);
        if (dayStartNav == 0) dayStartNav = nav();
        emit Deposited(token, amount, v);
    }

    /// @notice The owner can always withdraw, even while paused. The agent has no path to move funds out.
    function withdraw(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        uint256 bal = IERC20Min(token).balanceOf(address(this));
        require(amount <= bal, "bal");
        uint256 c;
        if (token == quoteToken) {
            c = amount;
        } else if (bal != 0) {
            c = costBasis[token] * amount / bal;
            costBasis[token] -= c;
        }
        netDeposits -= int256(c);
        require(IERC20Min(token).transfer(to, amount), "t");
        emit Withdrawn(token, amount, to);
    }

    // =========================================================================== agent actions
    /// @notice Records a decision that did not result in a trade (hold, signal, param suggestion).
    function logDecision(uint8 kind, bytes32 reasonHash, string calldata memo) external onlyAgent {
        emit Decision(++decisionCount, kind, reasonHash, memo);
    }

    /// @notice Agent asks for a swap. Returns false (and emits TradeBlocked) when any limit says no.
    function executeSwap(TradeRequest calldata r) external onlyAgent nonReentrant returns (bool ok, uint256 amountOut) {
        _rollDay();
        (Block code, uint256 floorOut) = checkTrade(r.tokenIn, r.tokenOut, r.fee, r.amountIn);
        if (code == Block.NONE) {
            uint256 minOut = r.minAmountOut > floorOut ? r.minAmountOut : floorOut;
            (bool swapped, uint256 out) = _trySwap(r.tokenIn, r.tokenOut, r.fee, r.amountIn, minOut);
            if (swapped) {
                int256 pnlD = _booksSwap(r.tokenIn, r.tokenOut, r.amountIn, out);
                _countTrade();
                emit TradeExecuted(++tradeCount, r.tokenIn, r.tokenOut, r.fee, r.amountIn, out, minOut, pnlD, r.reasonHash, r.memo);
                return (true, out);
            }
            code = Block.SLIPPAGE;
        }
        emit TradeBlocked(++blockedCount, code, r.tokenIn, r.tokenOut, r.amountIn, r.reasonHash, r.memo);
        return (false, 0);
    }

    /// @notice Atomic two-pool round trip (e.g. WHSK -> USDT on the 0.05% pool, USDT -> WHSK on the 0.3% pool).
    ///         Reverts internally and is logged as ARB_UNPROFITABLE unless tokenA grows by minProfitBps.
    function executeArbitrage(ArbRequest calldata r) external onlyAgent nonReentrant returns (bool ok, uint256 amountOut) {
        _rollDay();
        (Block code,) = checkTrade(r.tokenA, r.tokenB, r.feeSell, r.amountIn);
        if (code == Block.NONE) {
            (code,) = _poolChecks(r.tokenB, r.tokenA, r.feeBuy, 0);
        }
        if (code == Block.NONE) {
            try this.arbInner(r.tokenA, r.tokenB, r.feeSell, r.feeBuy, r.amountIn, r.minProfitBps) returns (uint256 out) {
                uint256 profit = out - r.amountIn;
                int256 pv = int256(valueOf(r.tokenA, profit));
                if (r.tokenA != quoteToken) costBasis[r.tokenA] += uint256(pv);
                realizedPnl += pv;
                _countTrade();
                emit ArbitrageExecuted(++tradeCount, r.tokenA, r.tokenB, r.feeSell, r.feeBuy, r.amountIn, out, r.reasonHash, r.memo);
                return (true, out);
            } catch {
                code = Block.ARB_UNPROFITABLE;
            }
        }
        emit TradeBlocked(++blockedCount, code, r.tokenA, r.tokenB, r.amountIn, r.reasonHash, r.memo);
        return (false, 0);
    }

    function arbInner(address a, address b, uint24 feeSell, uint24 feeBuy, uint256 amountIn, uint16 minProfitBps)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 mid = _swap(a, b, feeSell, amountIn, 0);
        out = _swap(b, a, feeBuy, mid, amountIn * (10_000 + minProfitBps) / 10_000);
        if (out < amountIn * (10_000 + minProfitBps) / 10_000) revert ArbFailed();
    }

    /// @notice Anyone may enforce the stop-loss: if a position's TWAP value is below its cost basis by more
    ///         than stopLossBps, the whole position is sold to the quote token through its reference pool.
    function triggerStopLoss(address token) external nonReentrant returns (uint256 out) {
        require(!paused, "paused");
        require(token != quoteToken && risk.stopLossBps != 0, "n/a");
        require(stopLossHit(token), "not hit");
        uint256 bal = IERC20Min(token).balanceOf(address(this));
        address pool = refPool[token];
        uint24 fee = IUniswapV3PoolLike(pool).fee();
        (bool okT, int24 tw) = _tryTwap(pool);
        require(okT, "oracle");
        uint256 expected = PoolOracle.quoteAtTick(tw, bal, token, quoteToken) * (1_000_000 - fee) / 1_000_000;
        uint256 minOut = expected * (10_000 - risk.maxSlippageBps) / 10_000;
        out = _swap(token, quoteToken, fee, bal, minOut);
        int256 pnlD = _booksSwap(token, quoteToken, bal, out);
        lastTradeAt = uint64(block.timestamp);
        emit StopLossTriggered(token, msg.sender, bal, out, pnlD);
        emit TradeExecuted(++tradeCount, token, quoteToken, fee, bal, out, minOut, pnlD, bytes32(0), "STOP_LOSS");
    }

    // ================================================================================== checks
    /// @notice Dry-run of every limit for a prospective trade. Returns the first failing check and the TWAP
    ///         output floor the vault would enforce. The agent calls this before asking, the dashboard shows it.
    function checkTrade(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        public
        view
        returns (Block code, uint256 floorOut)
    {
        if (paused) return (Block.PAUSED, 0);
        if (!allowedToken[tokenIn] || !allowedToken[tokenOut] || tokenIn == tokenOut) return (Block.TOKEN_NOT_ALLOWED, 0);
        if (IERC20Min(tokenIn).balanceOf(address(this)) < amountIn || amountIn == 0) {
            return (Block.INSUFFICIENT_BALANCE, 0);
        }
        uint256 vIn = valueOf(tokenIn, amountIn);
        if (vIn > risk.maxTradeQuote) return (Block.TRADE_TOO_LARGE, 0);
        if (lastTradeAt != 0 && block.timestamp < uint256(lastTradeAt) + risk.cooldown) return (Block.COOLDOWN, 0);
        if (_today() == currentDay && tradesToday >= risk.maxTradesPerDay) return (Block.FREQUENCY, 0);
        (code, floorOut) = _poolChecks(tokenIn, tokenOut, fee, amountIn);
        if (code != Block.NONE) return (code, 0);
        code = oracleCheck(tokenIn == quoteToken ? tokenOut : tokenIn);
        if (code != Block.NONE) return (code, 0);
        if (tokenOut != quoteToken) {
            uint256 n = nav();
            uint256 posAfter = valueOf(tokenOut, IERC20Min(tokenOut).balanceOf(address(this))) + vIn;
            if (posAfter * 10_000 > n * risk.maxPositionBps) return (Block.POSITION_LIMIT, 0);
            uint256 startNav = _today() == currentDay ? dayStartNav : n;
            if (n * 10_000 < startNav * (10_000 - risk.dailyLossBps)) return (Block.DAILY_LOSS_LIMIT, 0);
            if (risk.stopLossBps != 0 && stopLossHit(tokenOut)) return (Block.STOP_LOSS_ACTIVE, 0);
        }
    }

    function _poolChecks(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        view
        returns (Block, uint256 floorOut)
    {
        address pool = IUniswapV3FactoryLike(factory).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0) || !allowedPool[pool]) return (Block.POOL_NOT_ALLOWED, 0);
        (bool ok, int24 tw) = _tryTwap(pool);
        if (!ok) return (Block.ORACLE, 0);
        int24 sp = PoolOracle.spotTick(pool);
        int256 dev = int256(sp) - int256(tw);
        if (dev < 0) dev = -dev;
        if (uint256(dev) > risk.maxDeviationBps) return (Block.PRICE_DEVIATION, 0);
        if (amountIn > 0) {
            uint256 expected = PoolOracle.quoteAtTick(tw, amountIn, tokenIn, tokenOut) * (1_000_000 - fee) / 1_000_000;
            floorOut = expected * (10_000 - risk.maxSlippageBps) / 10_000;
        }
        return (Block.NONE, floorOut);
    }

    /// @notice Cross-checks the pool TWAP against the external USD feeds. Feeds are optional per token.
    function oracleCheck(address token) public view returns (Block) {
        uint256 quoteUsd = 1e18;
        OracleCfg memory q = quoteUsdOracle;
        if (q.feed != address(0)) {
            (bool okQ, uint256 pq) = _feedPrice(q);
            if (!okQ) return Block.ORACLE;
            uint256 d = pq > 1e18 ? pq - 1e18 : 1e18 - pq;
            if (d * 10_000 > uint256(q.maxDevBps) * 1e18) return Block.STABLE_DEPEG;
            quoteUsd = pq;
        }
        OracleCfg memory c = oracleOf[token];
        if (token == quoteToken || c.feed == address(0)) return Block.NONE;
        (bool ok, uint256 feedUsd) = _feedPrice(c);
        if (!ok) return Block.ORACLE;
        // TWAP price of 1 token in quote units, scaled to 1e18, then to USD via the quote feed
        uint256 one = 10 ** uint256(IERC20Min(token).decimals());
        uint256 twapUsd = valueOf(token, one) * 1e18 / (10 ** uint256(quoteDecimals)) * quoteUsd / 1e18;
        uint256 diff = twapUsd > feedUsd ? twapUsd - feedUsd : feedUsd - twapUsd;
        if (diff * 10_000 > feedUsd * c.maxDevBps) return Block.ORACLE_DEVIATION;
        return Block.NONE;
    }

    function _feedPrice(OracleCfg memory c) internal view returns (bool ok, uint256 price18) {
        try IAggregatorV3(c.feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt + c.maxAge < block.timestamp) return (false, 0);
            uint8 dec = IAggregatorV3(c.feed).decimals();
            return (true, uint256(answer) * 1e18 / (10 ** uint256(dec)));
        } catch {
            return (false, 0);
        }
    }

    // =================================================================================== views
    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    /// @notice Value of `amount` of `token` in quote units at the reference pool TWAP (spot if TWAP unavailable).
    function valueOf(address token, uint256 amount) public view returns (uint256) {
        if (token == quoteToken || amount == 0) return amount;
        address pool = refPool[token];
        if (pool == address(0)) return 0;
        (bool ok, int24 t) = _tryTwap(pool);
        if (!ok) t = PoolOracle.spotTick(pool);
        return PoolOracle.quoteAtTick(t, amount, token, quoteToken);
    }

    function nav() public view returns (uint256 total) {
        for (uint256 i; i < _tokens.length; i++) {
            address t = _tokens[i];
            total += valueOf(t, IERC20Min(t).balanceOf(address(this)));
        }
    }

    /// @return total nav - netDeposits; realized from closed trades; unrealized the rest. Quote units.
    function pnl() external view returns (int256 total, int256 realized, int256 unrealized) {
        total = int256(nav()) - netDeposits;
        realized = realizedPnl;
        unrealized = total - realized;
    }

    function position(address token)
        external
        view
        returns (uint256 balance, uint256 cost, uint256 value, uint256 priceTwapX18, uint256 priceSpotX18)
    {
        balance = IERC20Min(token).balanceOf(address(this));
        cost = token == quoteToken ? balance : costBasis[token];
        value = valueOf(token, balance);
        if (token == quoteToken) {
            priceTwapX18 = 1e18;
            priceSpotX18 = 1e18;
        } else if (refPool[token] != address(0)) {
            priceTwapX18 = valueOf(token, 1e18);
            priceSpotX18 = PoolOracle.quoteAtTick(PoolOracle.spotTick(refPool[token]), 1e18, token, quoteToken);
        }
    }

    function stopLossHit(address token) public view returns (bool) {
        if (token == quoteToken || risk.stopLossBps == 0) return false;
        uint256 bal = IERC20Min(token).balanceOf(address(this));
        if (bal == 0 || costBasis[token] == 0) return false;
        return valueOf(token, bal) * 10_000 < costBasis[token] * (10_000 - risk.stopLossBps);
    }

    function twapTickOf(address pool) external view returns (bool ok, int24 tick) {
        return _tryTwap(pool);
    }

    // ================================================================================ internals
    function _tryTwap(address pool) internal view returns (bool ok, int24 tick) {
        uint32 w = risk.twapWindow;
        uint32[] memory ago = new uint32[](2);
        ago[0] = w;
        try IUniswapV3PoolLike(pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[1] - cum[0];
            int56 ww = int56(uint56(w));
            tick = int24(delta / ww);
            if (delta < 0 && (delta % ww != 0)) tick--;
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _trySwap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 minOut)
        internal
        returns (bool, uint256)
    {
        IERC20Min(tokenIn).approve(router, amountIn);
        try ISwapRouter02(router).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams(tokenIn, tokenOut, fee, address(this), amountIn, minOut, 0)
        ) returns (uint256 out) {
            return (true, out);
        } catch {
            IERC20Min(tokenIn).approve(router, 0);
            return (false, 0);
        }
    }

    function _swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 out)
    {
        IERC20Min(tokenIn).approve(router, amountIn);
        out = ISwapRouter02(router).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams(tokenIn, tokenOut, fee, address(this), amountIn, minOut, 0)
        );
    }

    function _booksSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        returns (int256 pnlDelta)
    {
        uint256 balInBefore = IERC20Min(tokenIn).balanceOf(address(this)) + amountIn;
        uint256 removed;
        if (tokenIn == quoteToken) {
            removed = amountIn;
        } else {
            removed = costBasis[tokenIn] * amountIn / balInBefore;
            costBasis[tokenIn] -= removed;
        }
        if (tokenOut == quoteToken) {
            pnlDelta = int256(amountOut) - int256(removed);
            realizedPnl += pnlDelta;
        } else {
            costBasis[tokenOut] += removed;
        }
    }

    function _countTrade() internal {
        lastTradeAt = uint64(block.timestamp);
        tradesToday += 1;
    }

    function _today() internal view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }

    function _rollDay() internal {
        uint64 d = _today();
        if (d != currentDay) {
            currentDay = d;
            tradesToday = 0;
            dayStartNav = nav();
        }
    }
}
