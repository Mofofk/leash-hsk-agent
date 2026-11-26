// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LeashVault} from "../src/LeashVault.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IHSKSwap.sol";

/// Read-only simulation on a local fork of HSK Chain MAINNET (177): nothing is broadcast.
/// Proves the mainnet wiring (HSKSwap SwapRouter02, WHSK/USDT 0.3% pool, 6-decimal USDT) and the
/// APRO oracle cross-check against the real APRO HSK/USD and USDT/USD feeds listed in the HSK Chain docs.
/// Run: forge test --match-contract MainnetDryRun
contract MainnetDryRun is Test {
    address constant APRO_HSK_USD = 0x86CE42c1b714149Dc3A7b17169EF67b5F78A224b;
    address constant APRO_USDT_USD = 0x823d7f90f7A3498DB6595886b6B5dC95E6B0B7f3;
    address constant APRO_ACCESS_USDT = 0xbAed77076551B90982C63549Bf69e27c3E613CaD; // APRO access controllers
    address constant APRO_ACCESS_HSK = 0xb22daaaaDa8a6d55B150874a1E730161cB9846BC;

    function test_MainnetWiringAndAproCrossCheck() public {
        vm.createSelectFork("https://mainnet.hsk.xyz");
        Deploy d = new Deploy();
        Deploy.Net memory n = d.net(177);
        address owner = makeAddr("owner");
        address agent = makeAddr("agent");
        LeashVault.RiskParams memory p = d.defaultRisk(50e6); // 50 USDT (6 decimals)
        p.maxDeviationBps = 2000;
        LeashVault v = new LeashVault(owner, agent, n.router, n.factory, n.usdt, n.whsk, p, 3600);
        address pool = IUniswapV3FactoryLike(n.factory).getPool(n.whsk, n.usdt, 3000);
        assertTrue(pool != address(0));
        vm.startPrank(owner);
        v.configureToken(n.whsk, pool, true);
        v.configurePool(pool, true);
        v.setOracle(n.whsk, APRO_HSK_USD, 2 days, 500); // HSKSwap TWAP must sit within 5% of APRO
        v.setOracle(n.usdt, APRO_USDT_USD, 3 days, 100); // USDT within 1% of $1
        vm.deal(owner, 200 ether);
        v.depositNative{value: 100 ether}();
        vm.stopPrank();
        // APRO feeds on HSK mainnet are access-controlled for contracts: until APRO whitelists the vault,
        // the guard fails CLOSED (ORACLE) instead of trading blind.
        assertEq(uint8(v.oracleCheck(n.whsk)), uint8(LeashVault.Block.ORACLE));
        // simulate the whitelisting (the access controller answers hasAccess == true for our vault)
        vm.mockCall(APRO_ACCESS_USDT, abi.encodeWithSignature("hasAccess(address,bytes)"), abi.encode(true));
        vm.mockCall(APRO_ACCESS_HSK, abi.encodeWithSignature("hasAccess(address,bytes)"), abi.encode(true));
        assertEq(uint8(v.oracleCheck(n.whsk)), 0, "HSKSwap price disagrees with APRO");
        assertGt(v.nav(), 0);
        (LeashVault.Block code, uint256 floorOut) = v.checkTrade(n.whsk, n.usdt, 3000, 10 ether);
        assertEq(uint8(code), 0);
        vm.prank(agent);
        (bool ok, uint256 out) = v.executeSwap(LeashVault.TradeRequest(n.whsk, n.usdt, 3000, 10 ether, 0, bytes32(0), "mainnet dry run"));
        assertTrue(ok);
        assertGe(out, floorOut);
    }
}
