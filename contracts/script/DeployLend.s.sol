// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeashLend} from "../src/LeashLend.sol";

/// @notice Deploys LeashLend (WHSK collateral, USDT debt) on HSK Chain TESTNET, priced off the
///         HSKSwap WHSK/USDT 0.05% pool TWAP.
///   forge script script/DeployLend.s.sol --rpc-url hsk_testnet --broadcast \
///     --verify --verifier blockscout --verifier-url https://testnet-explorer.hskchain.net/api/
/// env: DEPLOYER_PK (owner)
contract DeployLend is Script {
    address constant WHSK = 0xCA8aAceEC5Db1e91B9Ed3a344bA026c4a2B3ebF6;
    address constant USDT = 0x98B6173A8B7DFc52ce8bc88f1184a918A1CCaa4F; // 18 decimals on testnet
    address constant POOL_500 = 0xff2b7E501C870980Bf5641B4a70D0F9fb0f6f6ab;

    function run() external returns (LeashLend lend) {
        require(block.chainid == 133, "testnet only");
        uint256 pk = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(pk);
        // sanity band for the TWAP: 1 .. 10,000 USDT per WHSK (testnet pools sit near 78)
        lend = new LeashLend(vm.addr(pk), WHSK, USDT, POOL_500, 1e18, 10_000e18);
        vm.stopBroadcast();
        console2.log("LeashLend", address(lend));
    }
}
