// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "./TickMath.sol";
import {FullMath} from "./FullMath.sol";
import {IUniswapV3PoolLike} from "../interfaces/IHSKSwap.sol";

/// @notice Reads HSKSwap (Uniswap V3 fork) pools: spot tick, TWAP tick via observe(), and tick -> quote conversion.
library PoolOracle {
    function spotTick(address pool) internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3PoolLike(pool).slot0();
    }

    /// @dev Arithmetic-mean tick over `window` seconds, rounded toward negative infinity.
    function twapTick(address pool, uint32 window) internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;
        (int56[] memory cum,) = IUniswapV3PoolLike(pool).observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 w = int56(uint56(window));
        int24 t = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) t--;
        return t;
    }

    /// @notice amount of quoteToken worth `baseAmount` of baseToken at `tick`.
    function quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        require(baseAmount <= type(uint128).max, "amt");
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
