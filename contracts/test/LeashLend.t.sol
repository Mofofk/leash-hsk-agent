// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LeashLend} from "../src/LeashLend.sol";
import {PoolOracle} from "../src/lib/PoolOracle.sol";

contract MockToken {
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Uniswap-V3-like pool whose TWAP tick and spot tick are set directly.
contract MockPool {
    address public token0;
    address public token1;
    int24 public twap;
    int24 public spot;
    bool public broken;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function set(int24 twap_, int24 spot_) external {
        twap = twap_;
        spot = spot_;
    }

    function breakIt(bool b) external {
        broken = b;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, spot, 0, 64, 64, 0, true);
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory cum, uint160[] memory l) {
        require(!broken, "OLD");
        cum = new int56[](ago.length);
        l = new uint160[](ago.length);
        for (uint256 i; i < ago.length; i++) {
            cum[i] = int56(twap) * int56(uint56(block.timestamp - ago[i]));
        }
    }
}

contract LeashLendUnitTest is Test {
    MockToken whsk;
    MockToken usdt;
    MockPool pool;
    LeashLend lend;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address liq = makeAddr("liquidator");

    function _tickFor(uint256 priceWad) internal view returns (int24 t) {
        // search the tick whose quote is closest to priceWad (USDT per 1e18 WHSK)
        int24 lo = -200000;
        int24 hi = 200000;
        bool up = PoolOracle.quoteAtTick(hi, 1e18, address(whsk), address(usdt)) > PoolOracle.quoteAtTick(lo, 1e18, address(whsk), address(usdt));
        while (hi - lo > 1) {
            int24 mid = (lo + hi) / 2;
            uint256 q = PoolOracle.quoteAtTick(mid, 1e18, address(whsk), address(usdt));
            if ((q < priceWad) == up) lo = mid;
            else hi = mid;
        }
        t = lo;
    }

    function _setPrice(uint256 priceWad) internal {
        int24 t = _tickFor(priceWad);
        pool.set(t, t);
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        whsk = new MockToken("WHSK");
        usdt = new MockToken("USDT");
        pool = new MockPool(address(whsk), address(usdt));
        _setPrice(78e18);
        lend = new LeashLend(owner, address(whsk), address(usdt), address(pool), 1e18, 10_000e18);
        usdt.mint(owner, 10_000e18);
        vm.startPrank(owner);
        usdt.approve(address(lend), type(uint256).max);
        lend.fund(1_000e18);
        vm.stopPrank();
        whsk.mint(alice, 10e18);
        usdt.mint(alice, 100e18);
        vm.startPrank(alice);
        whsk.approve(address(lend), type(uint256).max);
        usdt.approve(address(lend), type(uint256).max);
        vm.stopPrank();
        usdt.mint(liq, 1_000e18);
        vm.prank(liq);
        usdt.approve(address(lend), type(uint256).max);
    }

    function test_PriceNear78() public view {
        uint256 p = lend.price();
        assertApproxEqRel(p, 78e18, 0.001e18);
    }

    function test_DepositBorrowRepayWithdraw() public {
        vm.startPrank(alice);
        lend.depositCollateral(1e18);
        (,, uint256 val, uint256 maxB, uint256 avail, uint256 hf) = lend.position(alice);
        assertApproxEqRel(val, 78e18, 0.001e18);
        assertEq(maxB, val / 2);
        assertEq(avail, maxB);
        assertEq(hf, type(uint256).max);
        lend.borrow(30e18);
        assertEq(usdt.balanceOf(alice), 130e18);
        vm.warp(block.timestamp + 365 days);
        uint256 d = lend.debtOf(alice);
        assertApproxEqRel(d, 31.5e18, 0.0001e18); // 5% APR
        lend.repay(type(uint256).max);
        assertEq(lend.debtOf(alice), 0);
        assertEq(lend.totalScaledDebt(), 0);
        lend.withdrawCollateral(1e18);
        assertEq(whsk.balanceOf(alice), 10e18);
        vm.stopPrank();
        assertGt(lend.cash(), 1_000e18); // interest stayed in the pool
    }

    function test_BorrowAboveLtvReverts() public {
        vm.startPrank(alice);
        lend.depositCollateral(1e18);
        vm.expectRevert(LeashLend.ExceedsLtv.selector);
        lend.borrow(39.1e18);
        lend.borrow(38.9e18);
        vm.stopPrank();
    }

    function test_BorrowMoreThanCashReverts() public {
        whsk.mint(alice, 100e18);
        vm.startPrank(alice);
        lend.depositCollateral(100e18);
        vm.expectRevert(LeashLend.NoLiquidity.selector);
        lend.borrow(1_001e18);
        vm.stopPrank();
    }

    function test_WithdrawThatBreaksLtvReverts() public {
        vm.startPrank(alice);
        lend.depositCollateral(1e18);
        lend.borrow(30e18);
        vm.expectRevert(LeashLend.Unhealthy.selector);
        lend.withdrawCollateral(0.3e18);
        lend.withdrawCollateral(0.2e18); // 0.8 * 78 * 0.5 = 31.2 >= 30
        vm.stopPrank();
    }

    function test_LiquidationWhenUnhealthy() public {
        vm.startPrank(alice);
        lend.depositCollateral(1e18);
        lend.borrow(39e18);
        vm.stopPrank();
        vm.prank(liq);
        vm.expectRevert(LeashLend.Healthy.selector);
        lend.liquidate(alice, 10e18);
        _setPrice(55e18); // 39 / 55 = 70.9% > 65%
        (,,,,, uint256 hf) = lend.position(alice);
        assertLt(hf, 1e18);
        vm.prank(liq);
        (uint256 repaid, uint256 seized) = lend.liquidate(alice, 10e18);
        assertEq(repaid, 10e18);
        assertApproxEqRel(seized, uint256(10.5e18) * 1e18 / 55e18, 0.001e18);
        assertEq(whsk.balanceOf(liq), seized);
        assertApproxEqAbs(lend.debtOf(alice), 29e18, 1);
        (,,,,, uint256 hf2) = lend.position(alice);
        assertGt(hf2, hf);
    }

    function test_UnderwaterLiquidationCapsAtCollateral() public {
        vm.startPrank(alice);
        lend.depositCollateral(1e18);
        lend.borrow(39e18);
        vm.stopPrank();
        _setPrice(30e18);
        vm.prank(liq);
        (uint256 repaid, uint256 seized) = lend.liquidate(alice, type(uint256).max);
        assertEq(seized, 1e18);
        assertLt(repaid, 39e18);
        (uint256 c,,,,,) = lend.position(alice);
        assertEq(c, 0);
    }

    function test_SpotDeviationBlocksBorrow() public {
        vm.prank(alice);
        lend.depositCollateral(1e18);
        int24 t = pool.twap();
        pool.set(t, t + 600);
        vm.prank(alice);
        vm.expectRevert(LeashLend.SpotDeviates.selector);
        lend.borrow(1e18);
    }

    function test_PriceBandBlocksBorrow() public {
        vm.prank(alice);
        lend.depositCollateral(1e18);
        _setPrice(0.5e18);
        vm.prank(alice);
        vm.expectRevert(LeashLend.PriceOutOfBounds.selector);
        lend.borrow(0.1e18);
    }

    function test_OracleDownBlocksBorrowButViewsWork() public {
        vm.prank(alice);
        lend.depositCollateral(1e18);
        pool.breakIt(true);
        vm.prank(alice);
        vm.expectRevert(LeashLend.OracleUnavailable.selector);
        lend.borrow(1e18);
        (,,, uint256 p,, bool sane,) = lend.stats();
        assertEq(p, 0);
        assertFalse(sane);
        // no debt -> can still withdraw without the oracle
        vm.prank(alice);
        lend.withdrawCollateral(1e18);
    }

    function test_PauseBlocksBorrowNotRepay() public {
        vm.startPrank(alice);
        lend.depositCollateral(1e18);
        lend.borrow(10e18);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(LeashLend.NotOwner.selector);
        lend.setPaused(true);
        vm.prank(owner);
        lend.setPaused(true);
        vm.startPrank(alice);
        vm.expectRevert(LeashLend.IsPaused.selector);
        lend.borrow(1e18);
        lend.repay(type(uint256).max);
        lend.withdrawCollateral(1e18);
        vm.stopPrank();
    }

    function test_OwnerWithdrawsLiquidity() public {
        vm.prank(alice);
        vm.expectRevert(LeashLend.NotOwner.selector);
        lend.withdrawLiquidity(1e18, alice);
        vm.prank(owner);
        lend.withdrawLiquidity(400e18, owner);
        assertEq(lend.cash(), 600e18);
    }
}

/// Fork test against the live HSKSwap WHSK/USDT 0.05% pool on HSK Chain testnet.
/// Run: forge test --match-contract LeashLendForkTest --fork-url https://testnet.hsk.xyz -vv
contract LeashLendForkTest is Test {
    address constant WHSK = 0xCA8aAceEC5Db1e91B9Ed3a344bA026c4a2B3ebF6;
    address constant USDT = 0x98B6173A8B7DFc52ce8bc88f1184a918A1CCaa4F;
    address constant POOL_500 = 0xff2b7E501C870980Bf5641B4a70D0F9fb0f6f6ab;

    function test_LivePoolEndToEnd() public {
        vm.createSelectFork("https://testnet.hsk.xyz");
        address owner = makeAddr("owner");
        address user = makeAddr("user");
        LeashLend lend = new LeashLend(owner, WHSK, USDT, POOL_500, 1e18, 10_000e18);
        (bool ok, uint256 twapP, uint256 spotP,,, bool sane) = lend.oracle();
        assertTrue(ok);
        assertTrue(sane);
        assertGt(twapP, 0);
        assertApproxEqRel(twapP, spotP, 0.05e18);
        deal(USDT, owner, 100e18);
        vm.startPrank(owner);
        (bool s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(lend), type(uint256).max));
        require(s);
        lend.fund(100e18);
        vm.stopPrank();
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        (s,) = WHSK.call{value: 0.1 ether}(abi.encodeWithSignature("deposit()"));
        require(s);
        (s,) = WHSK.call(abi.encodeWithSignature("approve(address,uint256)", address(lend), type(uint256).max));
        require(s);
        (s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(lend), type(uint256).max));
        require(s);
        lend.depositCollateral(0.1 ether);
        (,,, uint256 maxB,,) = lend.position(user);
        lend.borrow(maxB / 2);
        vm.warp(block.timestamp + 60);
        deal(USDT, user, 1e18 + maxB / 2);
        lend.repay(type(uint256).max);
        lend.withdrawCollateral(0.1 ether);
        vm.stopPrank();
        assertEq(lend.debtOf(user), 0);
    }
}
