// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;

interface ITribeChief {
    function rewardMultipliers(uint256 _pid, uint256 _blocksLock)
        external
        returns (uint256);

    function deposit(
        uint256 _pid,
        uint256 _amount,
        uint64 _lockLength
    ) external;

    function withdrawFromDeposit(
        uint256 pid,
        uint256 amount,
        address to,
        uint256 index
    ) external;

    function withdrawAllAndHarvest(uint256 _pid, address _to) external;

    function harvest(uint256 _pid, address _to) external;

    function getTotalStakedInPool(uint256 _pid, address _user)
        external
        view
        returns (uint256);

    function pendingRewards(uint256 _pid, address _user)
        external
        view
        returns (uint256);

    function emergencyWithdraw(uint256 pid, address to) external;
}
