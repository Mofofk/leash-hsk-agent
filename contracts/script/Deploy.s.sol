// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeashVault} from "../src/LeashVault.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IHSKSwap.sol";

/// @notice Deploys LeashVault on HSK Chain and wires it to HSKSwap.
///   testnet (133): forge script script/Deploy.s.sol --rpc-url hsk_testnet --broadcast
///   mainnet (177): see DeployMainnet.s.sol (prepared, not run)
/// env: DEPLOYER_PK (owner), AGENT_ADDR, MAX_TRADE_QUOTE (quote units, optional)
contract Deploy is Script {
    struct Net {
        address factory;
        address router;
        address whsk;
        address usdt;
    }

    function net(uint256 chainId) public pure returns (Net memory n) {
        if (chainId == 133) {
            n = Net(
                0x2dC2c21D1049F786C535bF9d45F999dB5474f3A0, // HSKSwap V3 factory (testnet)
                0xa6914E66690c6794244B5f66a09eAEbf66254237, // HSKSwap SwapRouter02 (testnet)
                0xCA8aAceEC5Db1e91B9Ed3a344bA026c4a2B3ebF6, // WHSK (testnet)
                0x98B6173A8B7DFc52ce8bc88f1184a918A1CCaa4F // USDT, 18 decimals (testnet)
            );
        } else if (chainId == 177) {
            n = Net(
                0x972cA9D1662F5e029cD18327D29026532E84c742, // HSKSwap V3 factory (mainnet)
                0x2c16f75b95Cf1390c328aB70e2CEE7f4b80bD8F3, // HSKSwap SwapRouter02 (mainnet)
                0xB210D2120d57b758EE163cFfb43e73728c471Cf1, // WHSK (mainnet)
                0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029 // USDT, 6 decimals (mainnet)
            );
        } else {
            revert("unsupported chain");
        }
    }

    function defaultRisk(uint128 maxTradeQuote) public pure returns (LeashVault.RiskParams memory) {
        return LeashVault.RiskParams({
            maxTradeQuote: maxTradeQuote,
            maxPositionBps: 10_000,
            maxSlippageBps: 200,
            maxDeviationBps: 300,
            dailyLossBps: 500,
            stopLossBps: 1000,
            cooldown: 60,
            maxTradesPerDay: 48,
            twapWindow: 300
        });
    }

    function run() external returns (LeashVault vault) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address agent = vm.envAddress("AGENT_ADDR");
        Net memory n = net(block.chainid);
        uint128 maxTrade = uint128(vm.envOr("MAX_TRADE_QUOTE", uint256(1e18)));
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        uint32 delay = uint32(vm.envOr("LOOSEN_DELAY", block.chainid == 177 ? uint256(1 hours) : uint256(10 minutes)));
        vault = new LeashVault(owner, agent, n.router, n.factory, n.usdt, n.whsk, defaultRisk(maxTrade), delay);
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        address ref;
        for (uint256 i; i < fees.length; i++) {
            address p = IUniswapV3FactoryLike(n.factory).getPool(n.whsk, n.usdt, fees[i]);
            if (p == address(0)) continue;
            if (ref == address(0)) ref = p; // deepest-priority tier first: 0.05%
            if (fees[i] != 10000) vault.configurePool(p, true);
        }
        require(ref != address(0), "no WHSK/USDT pool");
        vault.configureToken(n.whsk, ref, true);
        if (block.chainid == 177) {
            // APRO price feeds listed in the HSK Chain docs. APRO must whitelist the vault for contract reads;
            // until then the vault fails closed (Block.ORACLE) rather than trading without the cross-check.
            vault.setOracle(n.whsk, 0x86CE42c1b714149Dc3A7b17169EF67b5F78A224b, 2 days, 500); // HSK/USD within 5%
            vault.setOracle(n.usdt, 0x823d7f90f7A3498DB6595886b6B5dC95E6B0B7f3, 3 days, 100); // USDT depeg > 1% halts
        }
        // On testnet the APRO feeds are stale and the pools are synthetic (WHSK ~78 USDT), so the
        // oracle cross-check is left off there; the TWAP, deviation and every other guard stay on.
        vm.stopBroadcast();
        console2.log("LeashVault", address(vault));
        console2.log("refPool", ref);
    }
}
