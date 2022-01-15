// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;

interface IStableSwap {
    function add_liquidity(uint256[] memory _amounts, uint256 _minMintAmount)
        external
        returns (uint256);

    function calc_token_amount(uint256[] memory _amounts, bool _isDeposit)
        external
        view
        returns (uint256);

    function get_virtual_price() external view returns (uint256);
}
