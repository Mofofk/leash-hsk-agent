// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Deploy} from "./Deploy.s.sol";

/// @notice HSK Chain MAINNET (chain 177) deployment, prepared for the post-hackathon mainnet requirement.
///         NOT run during the hackathon. To use (real HSK for gas):
///   export DEPLOYER_PK=<owner key> AGENT_ADDR=<agent hot wallet> MAX_TRADE_QUOTE=50000000   # 50 USDT, 6 decimals
///   forge script script/DeployMainnet.s.sol --rpc-url hsk_mainnet --broadcast --verify \
///     --verifier blockscout --verifier-url https://hsk.blockscout.com/api/
contract DeployMainnet is Deploy {
    function setUp() public view {
        require(block.chainid == 177, "DeployMainnet: point --rpc-url at HSK mainnet (177)");
    }
}
