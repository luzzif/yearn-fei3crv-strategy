// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 _amountIn, address[] memory _path)
        external
        view
        returns (uint256[] memory amounts);
}
