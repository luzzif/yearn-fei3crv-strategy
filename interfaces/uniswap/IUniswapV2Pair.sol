// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;

interface IUniswapV2Pair {
    function getReserves()
        external
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        );
}
