// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Import your main contract and the mock token contract.
// Make sure these files are in the same directory or adjust the paths accordingly.
import "./LiquidityAccelerationToken.sol";
import "./MockLAT.sol"; // A simple ERC20 token that implements ILatToken.

contract TestLiquidityAccelerationToken {
    LiquidityAccelerationToken public latContract;
    MockLAT public mockLAT;

    constructor() {
        // Deploy the mock LAT token.
        mockLAT = new MockLAT("LAT Token", "LAT");
        // Deploy the LiquidityAccelerationToken contract.
        latContract = new LiquidityAccelerationToken();
        latContract.initialize(
            ILatToken(address(mockLAT)),
            100,      // tradeRewardRate
            200,      // stakeRewardRate
            3600,     // tradeEpochDuration (seconds)
            50000,    // poolVolumeThreshold
            120,      // poolBoostMultiplier
            6500,     // epochDuration (blocks)
            msg.sender // vaultAddress (using deployer for testing)
        );
    }

    // Test function for recording a trade.
    function testRecordTrade() public {
        // Call recordTrade.
        latContract.recordTrade(1000, true);
        // Retrieve trader statistics.
        (uint256 tradeCount, uint256 totalVolume, , ) = latContract.traderStats(msg.sender);
        require(tradeCount == 1, "Trade count should be 1");
        require(totalVolume == 1000, "Total volume should be 1000");
    }

    // Test function for staking LAT tokens.
    function testStakeLat() public {
        // Mint LAT tokens to the caller.
        mockLAT.mint(msg.sender, 100 ether);
        // Approve the LiquidityAccelerationToken contract to spend tokens.
        mockLAT.approve(address(latContract), 50 ether);
        // Stake 50 LAT tokens.
        latContract.stakeLat(50 ether);
        // Retrieve staking information.
        (uint256 amount, , ) = latContract.stakes(msg.sender);
        require(amount == 50 ether, "Staked amount should be 50 ether");
    }
}
