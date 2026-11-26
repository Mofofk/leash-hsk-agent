// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LeashVault} from "../src/LeashVault.sol";
import {TickMath} from "../src/lib/TickMath.sol";
import {IERC20Min, IUniswapV3PoolLike, ISwapRouter02} from "../src/interfaces/IHSKSwap.sol";

contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals = 8;

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// Fork tests against the live HSKSwap deployment on HSK Chain testnet (chain 133).
/// Run: forge test --fork-url https://testnet.hsk.xyz -vv
contract LeashVaultForkTest is Test {
    address constant FACTORY = 0x2dC2c21D1049F786C535bF9d45F999dB5474f3A0;
    address constant ROUTER = 0xa6914E66690c6794244B5f66a09eAEbf66254237; // SwapRouter02
    address constant WHSK = 0xCA8aAceEC5Db1e91B9Ed3a344bA026c4a2B3ebF6;
    address constant USDT = 0x98B6173A8B7DFc52ce8bc88f1184a918A1CCaa4F;
    address constant POOL_500 = 0xff2b7E501C870980Bf5641B4a70D0F9fb0f6f6ab;
    address constant POOL_3000 = 0xc076FB478b77633736738579c7f48D2539604a50;
    address constant POOL_10000 = 0xEcb84943b34b31A0eAD637D073Bf6AB891c277Fc;

    LeashVault vault;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address keeper = makeAddr("keeper");

    event TradeBlocked(
        uint256 indexed id, LeashVault.Block indexed code, address tokenIn, address tokenOut, uint256 amountIn, bytes32 reasonHash, string memo
    );

    function _params() internal pure returns (LeashVault.RiskParams memory p) {
        p = LeashVault.RiskParams({
            maxTradeQuote: 50e18,
            maxPositionBps: 10_000,
            maxSlippageBps: 300,
            maxDeviationBps: 500,
            dailyLossBps: 1000,
            stopLossBps: 800,
            cooldown: 60,
            maxTradesPerDay: 20,
            twapWindow: 300
        });
    }

    function setUp() public {
        vm.createSelectFork("https://testnet.hsk.xyz");
        vault = new LeashVault(owner, agent, ROUTER, FACTORY, USDT, WHSK, _params(), 0);
        vm.startPrank(owner);
        vault.configureToken(WHSK, POOL_500, true);
        vault.configurePool(POOL_500, true);
        vault.configurePool(POOL_3000, true);
        vm.deal(owner, 10 ether);
        vault.depositNative{value: 2 ether}();
        vm.stopPrank();
    }

    function _req(address tin, address tout, uint24 fee, uint256 amt) internal pure returns (LeashVault.TradeRequest memory) {
        return LeashVault.TradeRequest(tin, tout, fee, amt, 0, keccak256("reason"), "test");
    }

    // ------------------------------------------------------------------- math vs live pool
    function test_TickMathMatchesLivePool() public view {
        (uint160 sqrtP, int24 tick,,,,,) = IUniswapV3PoolLike(POOL_500).slot0();
        assertLe(TickMath.getSqrtRatioAtTick(tick), sqrtP);
        assertGt(TickMath.getSqrtRatioAtTick(tick + 1), sqrtP);
    }

    function test_DepositValuedAtTwap() public view {
        uint256 n = vault.nav();
        assertGt(n, 0);
        assertEq(int256(n), vault.netDeposits());
        (uint256 bal, uint256 cost,,,) = vault.position(WHSK);
        assertEq(bal, 2 ether);
        assertEq(cost, n);
    }

    // ------------------------------------------------------------------------ happy path
    function test_AgentSellExecutesWithTwapFloor() public {
        vm.prank(agent);
        (bool ok, uint256 out) = vault.executeSwap(_req(WHSK, USDT, 500, 0.1 ether));
        assertTrue(ok);
        assertGt(out, 0);
        assertEq(IERC20Min(USDT).balanceOf(address(vault)), out);
        assertEq(vault.tradeCount(), 1);
        (int256 total, int256 realized,) = vault.pnl();
        // selling at the pool price costs roughly the 0.05% fee plus impact, never more than the slippage cap
        assertGt(realized, -int256(out * 300 / 10_000));
        assertLe(total, 0);
    }

    function test_SlippageFloorReplacesAgentZeroMin() public {
        (LeashVault.Block code, uint256 floorOut) = vault.checkTrade(WHSK, USDT, 500, 0.1 ether);
        assertEq(uint8(code), 0);
        assertGt(floorOut, 0);
        vm.recordLogs();
        vm.prank(agent);
        (bool ok, uint256 out) = vault.executeSwap(_req(WHSK, USDT, 500, 0.1 ether));
        assertTrue(ok);
        assertGe(out, floorOut);
    }

    // ---------------------------------------------------------------------- guard blocks
    function test_BlocksTradeTooLarge() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit TradeBlocked(1, LeashVault.Block.TRADE_TOO_LARGE, WHSK, USDT, 1.5 ether, bytes32(0), "");
        vm.prank(agent);
        (bool ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 1.5 ether)); // ~110 USDT > 50 cap
        assertFalse(ok);
        assertEq(IERC20Min(WHSK).balanceOf(address(vault)), 2 ether);
        assertEq(vault.blockedCount(), 1);
    }

    function test_BlocksTokenNotAllowed() public {
        (LeashVault.Block code,) = vault.checkTrade(WHSK, address(0xBEEF), 500, 0.1 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.TOKEN_NOT_ALLOWED));
    }

    function test_BlocksPoolNotAllowed() public {
        (LeashVault.Block code,) = vault.checkTrade(WHSK, USDT, 10000, 0.1 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.POOL_NOT_ALLOWED));
    }

    function test_CooldownAndFrequency() public {
        vm.startPrank(agent);
        (bool ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        assertTrue(ok);
        (ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        assertFalse(ok); // cooldown
        vm.stopPrank();
        (LeashVault.Block code,) = vault.checkTrade(WHSK, USDT, 500, 0.01 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.COOLDOWN));

        LeashVault.RiskParams memory p = _params();
        p.maxTradesPerDay = 1;
        vm.prank(owner);
        vault.setRiskParams(p, "only one trade a day");
        vm.warp(block.timestamp + 120);
        (code,) = vault.checkTrade(WHSK, USDT, 500, 0.01 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.FREQUENCY));
    }

    function test_KillSwitch() public {
        vm.prank(owner);
        vault.pause("user hit kill switch");
        vm.prank(agent);
        (bool ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        assertFalse(ok);
        vm.prank(agent);
        vm.expectRevert(LeashVault.NotOwner.selector);
        vault.unpause();
        // owner can still withdraw while paused
        vm.prank(owner);
        vault.withdraw(WHSK, 1 ether, owner);
        assertEq(IERC20Min(WHSK).balanceOf(owner), 1 ether);
        vm.prank(owner);
        vault.unpause();
        vm.prank(agent);
        (ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        assertTrue(ok);
    }

    function test_AgentHasNoPathToFunds() public {
        vm.startPrank(agent);
        vm.expectRevert(LeashVault.NotOwner.selector);
        vault.withdraw(WHSK, 1, agent);
        vm.expectRevert(LeashVault.NotOwner.selector);
        vault.setRiskParams(_params(), "agent tries to loosen limits");
        vm.expectRevert(LeashVault.NotOwner.selector);
        vault.configurePool(POOL_10000, true);
        vm.expectRevert(LeashVault.NotOwner.selector);
        vault.setAgent(agent);
        vm.expectRevert(LeashVault.OnlySelf.selector);
        vault.arbInner(WHSK, USDT, 500, 3000, 1 ether, 0);
        vm.stopPrank();
        vm.expectRevert(LeashVault.NotAgent.selector);
        vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
    }

    function test_HardCapsBindEvenTheOwner() public {
        LeashVault.RiskParams memory p = _params();
        p.maxSlippageBps = 2500;
        vm.prank(owner);
        vm.expectRevert(LeashVault.BadParams.selector);
        vault.setRiskParams(p, "yolo 25% slippage");
        p = _params();
        p.stopLossBps = 10;
        vm.prank(owner);
        vm.expectRevert(LeashVault.BadParams.selector);
        vault.setRiskParams(p, "tiny stop");
    }

    function test_ConfigureRejectsFakePool() public {
        vm.prank(owner);
        vm.expectRevert();
        vault.configurePool(address(0xdead), true);
    }

    function test_PositionLimit() public {
        deal(USDT, owner, 1000e18);
        vm.startPrank(owner);
        IERC20Min(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(USDT, 100e18);
        LeashVault.RiskParams memory p = _params();
        p.maxPositionBps = 5000;
        vault.setRiskParams(p, "max half the book in one coin");
        vm.stopPrank();
        // vault already ~100% WHSK, so buying more WHSK breaches the 50% cap
        (LeashVault.Block code,) = vault.checkTrade(USDT, WHSK, 500, 10e18);
        assertEq(uint8(code), uint8(LeashVault.Block.POSITION_LIMIT));
    }

    // ------------------------------------------------- manipulation, stop-loss, breaker
    function _whaleDump(uint256 amt) internal {
        address whale = makeAddr("whale");
        vm.deal(whale, amt);
        vm.startPrank(whale);
        (bool s,) = WHSK.call{value: amt}(abi.encodeWithSignature("deposit()"));
        require(s);
        IERC20Min(WHSK).approve(ROUTER, amt);
        ISwapRouter02(ROUTER).exactInputSingle(ISwapRouter02.ExactInputSingleParams(WHSK, USDT, 500, whale, amt, 0, 0));
        vm.stopPrank();
    }

    function test_DeviationGuardBlocksManipulatedPool() public {
        _whaleDump(200 ether);
        (LeashVault.Block code,) = vault.checkTrade(WHSK, USDT, 500, 0.1 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.PRICE_DEVIATION));
    }

    function test_StopLossAnyoneCanEnforce() public {
        assertFalse(vault.stopLossHit(WHSK));
        vm.expectRevert(bytes("not hit"));
        vault.triggerStopLoss(WHSK);
        _whaleDump(200 ether);
        vm.warp(block.timestamp + 600); // TWAP now fully reflects the crash
        vm.roll(block.number + 50);
        assertTrue(vault.stopLossHit(WHSK));
        vm.prank(keeper);
        uint256 out = vault.triggerStopLoss(WHSK);
        assertGt(out, 0);
        assertEq(IERC20Min(WHSK).balanceOf(address(vault)), 0);
        assertLt(vault.realizedPnl(), 0);
    }

    function test_DailyLossBreakerOnlyAllowsDeRisking() public {
        deal(USDT, owner, 1000e18);
        vm.startPrank(owner);
        IERC20Min(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(USDT, 20e18);
        LeashVault.RiskParams memory p = _params();
        p.stopLossBps = 0; // isolate the breaker
        p.maxDeviationBps = 2000;
        vault.setRiskParams(p, "breaker test");
        vm.stopPrank();
        vm.prank(agent);
        vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether)); // rolls the day, records start NAV
        _whaleDump(200 ether);
        vm.warp(block.timestamp + 600);
        (LeashVault.Block code,) = vault.checkTrade(USDT, WHSK, 500, 1e18);
        assertEq(uint8(code), uint8(LeashVault.Block.DAILY_LOSS_LIMIT));
        (code,) = vault.checkTrade(WHSK, USDT, 500, 0.01 ether); // selling is still allowed
        assertEq(uint8(code), 0);
    }

    // ----------------------------------------------------------------------- arbitrage
    function test_ArbitrageAcrossFeeTiers() public {
        // The live testnet 0.05% and 0.3% WHSK/USDT pools trade at different prices.
        (, int24 t500,,,,,) = IUniswapV3PoolLike(POOL_500).slot0();
        (, int24 t3000,,,,,) = IUniswapV3PoolLike(POOL_3000).slot0();
        // token0 = USDT, token1 = WHSK; lower tick => WHSK is worth more USDT
        (uint24 sellFee, uint24 buyFee) = t500 < t3000 ? (uint24(500), uint24(3000)) : (uint24(3000), uint24(500));
        uint256 before = IERC20Min(WHSK).balanceOf(address(vault));
        vm.prank(agent);
        (bool ok, uint256 out) = vault.executeArbitrage(
            LeashVault.ArbRequest(WHSK, USDT, sellFee, buyFee, 0.05 ether, 50, keccak256("arb"), "fee-tier spread")
        );
        assertTrue(ok);
        assertGt(out, 0.05 ether);
        assertEq(IERC20Min(WHSK).balanceOf(address(vault)), before - 0.05 ether + out);
        assertGt(vault.realizedPnl(), 0);

        // the wrong direction can never lose money: it reverts atomically and is logged as blocked
        vm.warp(block.timestamp + 120);
        vm.prank(agent);
        (ok,) = vault.executeArbitrage(
            LeashVault.ArbRequest(WHSK, USDT, buyFee, sellFee, 0.05 ether, 0, keccak256("arb2"), "wrong way")
        );
        assertFalse(ok);
        assertEq(IERC20Min(WHSK).balanceOf(address(vault)), before - 0.05 ether + out);
    }

    // ----------------------------------------------------------------- oracle cross-check
    function _twapUsd8() internal view returns (int256) {
        (,,, uint256 pt,) = vault.position(WHSK);
        return int256(pt / 1e10); // 18 -> 8 decimals
    }

    function test_OracleGuardPassesWhenFeedAgrees() public {
        MockFeed f = new MockFeed();
        f.set(_twapUsd8(), block.timestamp);
        vm.prank(owner);
        vault.setOracle(WHSK, address(f), 3600, 300);
        assertEq(uint8(vault.oracleCheck(WHSK)), 0);
        vm.prank(agent);
        (bool ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        assertTrue(ok);
    }

    function test_OracleGuardBlocksWhenPoolDisagreesWithFeed() public {
        MockFeed f = new MockFeed();
        f.set(_twapUsd8() * 80 / 100, block.timestamp); // feed says 20% lower than the pool
        vm.prank(owner);
        vault.setOracle(WHSK, address(f), 3600, 300);
        vm.prank(agent);
        (bool ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        assertFalse(ok);
        (LeashVault.Block code,) = vault.checkTrade(WHSK, USDT, 500, 0.01 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.ORACLE_DEVIATION));
    }

    function test_StaleOracleBlocks() public {
        MockFeed f = new MockFeed();
        f.set(_twapUsd8(), block.timestamp - 2 hours);
        vm.prank(owner);
        vault.setOracle(WHSK, address(f), 3600, 300);
        (LeashVault.Block code,) = vault.checkTrade(WHSK, USDT, 500, 0.01 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.ORACLE));
    }

    function test_StablecoinDepegGuard() public {
        MockFeed q = new MockFeed();
        q.set(0.95e8, block.timestamp); // USDT at 0.95
        vm.prank(owner);
        vault.setOracle(USDT, address(q), 86400, 100); // tolerate 1%
        (LeashVault.Block code,) = vault.checkTrade(WHSK, USDT, 500, 0.01 ether);
        assertEq(uint8(code), uint8(LeashVault.Block.STABLE_DEPEG));
        q.set(0.998e8, block.timestamp);
        (code,) = vault.checkTrade(WHSK, USDT, 500, 0.01 ether);
        assertEq(uint8(code), 0);
    }

    function test_SetOracleBounds() public {
        vm.prank(owner);
        vm.expectRevert(LeashVault.BadParams.selector);
        vault.setOracle(WHSK, address(1), 0, 300);
        vm.prank(agent);
        vm.expectRevert(LeashVault.NotOwner.selector);
        vault.setOracle(WHSK, address(0), 0, 0);
    }

    // --------------------------------------------------------------- more lifecycle
    function test_RevokedAgentIsLockedOut() public {
        address agent2 = makeAddr("agent2");
        vm.prank(owner);
        vault.setAgent(agent2);
        vm.prank(agent);
        vm.expectRevert(LeashVault.NotAgent.selector);
        vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        vm.prank(agent2);
        (bool ok,) = vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        assertTrue(ok);
    }

    function test_AgentMayPauseButNeverUnpause() public {
        vm.prank(agent);
        vault.pause("agent detected anomaly");
        assertTrue(vault.paused());
        vm.prank(agent);
        vm.expectRevert(LeashVault.NotOwner.selector);
        vault.unpause();
    }

    function test_StopLossRespectsKillSwitch() public {
        _whaleDump(200 ether);
        vm.warp(block.timestamp + 600);
        assertTrue(vault.stopLossHit(WHSK));
        vm.prank(owner);
        vault.pause("hold everything");
        vm.expectRevert(bytes("paused"));
        vault.triggerStopLoss(WHSK);
    }

    function test_StopLossBlocksBuyingMoreOfALosingPosition() public {
        deal(USDT, owner, 100e18);
        vm.startPrank(owner);
        IERC20Min(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(USDT, 50e18);
        LeashVault.RiskParams memory p = _params();
        p.maxDeviationBps = 2000;
        p.dailyLossBps = 5000;
        vault.setRiskParams(p, "loose for test");
        vm.stopPrank();
        _whaleDump(150 ether);
        vm.warp(block.timestamp + 600);
        (LeashVault.Block code,) = vault.checkTrade(USDT, WHSK, 500, 1e18);
        assertEq(uint8(code), uint8(LeashVault.Block.STOP_LOSS_ACTIVE));
    }

    function test_DailyBreakerResetsNextDay() public {
        deal(USDT, owner, 1000e18);
        vm.startPrank(owner);
        IERC20Min(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(USDT, 20e18);
        LeashVault.RiskParams memory p = _params();
        p.stopLossBps = 0;
        p.maxDeviationBps = 2000;
        vault.setRiskParams(p, "breaker test");
        vm.stopPrank();
        vm.prank(agent);
        vault.executeSwap(_req(WHSK, USDT, 500, 0.01 ether));
        _whaleDump(200 ether);
        vm.warp(block.timestamp + 600);
        (LeashVault.Block code,) = vault.checkTrade(USDT, WHSK, 500, 1e18);
        assertEq(uint8(code), uint8(LeashVault.Block.DAILY_LOSS_LIMIT));
        vm.warp(block.timestamp + 1 days);
        vm.prank(agent);
        vault.executeSwap(_req(WHSK, USDT, 500, 0.001 ether)); // first trade of the new day re-bases NAV
        vm.warp(block.timestamp + 120); // past the cooldown
        (code,) = vault.checkTrade(USDT, WHSK, 500, 1e18);
        assertEq(uint8(code), 0);
    }

    function test_WithdrawKeepsPnlHonest() public {
        vm.prank(agent);
        vault.executeSwap(_req(WHSK, USDT, 500, 0.1 ether));
        (int256 before,,) = vault.pnl();
        vm.prank(owner);
        vault.withdraw(WHSK, 1 ether, owner);
        (int256 afterW,,) = vault.pnl();
        assertApproxEqAbs(afterW, before, 1e12);
    }

    function testFuzz_TwapFloorAlwaysHolds(uint256 amt) public {
        amt = bound(amt, 1e12, 0.5 ether);
        (LeashVault.Block code, uint256 floorOut) = vault.checkTrade(WHSK, USDT, 500, amt);
        vm.assume(code == LeashVault.Block.NONE);
        vm.prank(agent);
        (bool ok, uint256 out) = vault.executeSwap(_req(WHSK, USDT, 500, amt));
        assertTrue(ok);
        assertGe(out, floorOut);
        assertEq(IERC20Min(WHSK).balanceOf(address(vault)), 2 ether - amt);
    }
}

/// Timelocked loosening: a separate suite whose vault has a 10-minute loosen delay.
contract LeashVaultTimelockTest is Test {
    address constant FACTORY = 0x2dC2c21D1049F786C535bF9d45F999dB5474f3A0;
    address constant ROUTER = 0xa6914E66690c6794244B5f66a09eAEbf66254237;
    address constant WHSK = 0xCA8aAceEC5Db1e91B9Ed3a344bA026c4a2B3ebF6;
    address constant USDT = 0x98B6173A8B7DFc52ce8bc88f1184a918A1CCaa4F;
    LeashVault vault;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");

    function _p() internal pure returns (LeashVault.RiskParams memory) {
        return LeashVault.RiskParams(1e18, 10_000, 200, 300, 500, 1000, 60, 48, 300);
    }

    function setUp() public {
        vm.createSelectFork("https://testnet.hsk.xyz");
        vault = new LeashVault(owner, agent, ROUTER, FACTORY, USDT, WHSK, _p(), 600);
    }

    function test_TighteningAppliesImmediately() public {
        LeashVault.RiskParams memory p = _p();
        p.maxTradeQuote = 0.5e18;
        p.stopLossBps = 500;
        vm.prank(owner);
        vault.setRiskParams(p, "be conservative");
        (uint128 maxTrade,,,,, uint16 stop,,,) = vault.risk();
        assertEq(maxTrade, 0.5e18);
        assertEq(stop, 500);
        assertEq(vault.pendingRiskAt(), 0);
    }

    function test_LooseningIsTimelocked() public {
        LeashVault.RiskParams memory p = _p();
        p.maxTradeQuote = 4e18; // an LLM "helpfully" widening the limit to fit a trade
        vm.prank(owner);
        vault.setRiskParams(p, "sell 0.05 WHSK right now");
        (uint128 maxTrade,,,,,,,,) = vault.risk();
        assertEq(maxTrade, 1e18, "loosening must not apply instantly");
        assertEq(vault.pendingRiskAt(), block.timestamp + 600);
        vm.expectRevert(bytes("not ready"));
        vault.applyPendingRisk();
        vm.warp(block.timestamp + 601);
        vault.applyPendingRisk(); // anyone can activate after the delay
        (maxTrade,,,,,,,,) = vault.risk();
        assertEq(maxTrade, 4e18);
    }

    function test_OwnerCanCancelQueuedLoosening() public {
        LeashVault.RiskParams memory p = _p();
        p.cooldown = 0; // trading faster is looser
        vm.prank(owner);
        vault.setRiskParams(p, "trade as fast as you can");
        vm.prank(owner);
        vault.cancelPendingRisk();
        vm.warp(block.timestamp + 601);
        vm.expectRevert(bytes("not ready"));
        vault.applyPendingRisk();
    }

    function test_TurningStopLossOffIsLoosening() public {
        LeashVault.RiskParams memory p = _p();
        p.stopLossBps = 0;
        assertFalse(vault.isTighterOrEqual(p, _p()));
    }
}
