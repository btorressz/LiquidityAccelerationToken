/*
  Test Script for LiquidityAccelerationToken in Remix
*/
//TODO: edit test file

(async function() {
  // Get accounts from Remix's JavaScript VM.
  const accounts = await web3.eth.getAccounts();
  console.log("Accounts:", accounts);
  const owner = accounts[0];
  const user1 = accounts[1];

  // --- Deploy MockLAT token ---
  // Replace with the actual ABI and bytecode of your MockLAT contract.
  const mockLATABI = [ /* ... ABI for MockLAT ... */ ];
  const mockLATBytecode = "0x..."; // Bytecode for MockLAT

  const MockLAT = new web3.eth.Contract(mockLATABI);
  const mockLATInstance = await MockLAT.deploy({
    data: mockLATBytecode,
    arguments: ["LAT Token", "LAT"]
  }).send({ from: owner, gas: 3000000 });
  console.log("MockLAT deployed at:", mockLATInstance.options.address);

  // --- Deploy LiquidityAccelerationToken ---
  // Replace with the actual ABI and bytecode of  LiquidityAccelerationToken contract.
  const latContractABI = [ /* ... ABI for LiquidityAccelerationToken ... */ ];
  const latContractBytecode = "0x..."; // Bytecode for LiquidityAccelerationToken

  const LATContract = new web3.eth.Contract(latContractABI);
  const latContractInstance = await LATContract.deploy({
    data: latContractBytecode
  }).send({ from: owner, gas: 3000000 });
  console.log("LiquidityAccelerationToken deployed at:", latContractInstance.options.address);

  // --- Initialize the contract ---
  await latContractInstance.methods.initialize(
    mockLATInstance.options.address, // LAT token address
    100,      // tradeRewardRate
    200,      // stakeRewardRate
    3600,     // tradeEpochDuration (seconds)
    50000,    // poolVolumeThreshold
    120,      // poolBoostMultiplier
    6500,     // epochDuration (blocks)
    owner     // vaultAddress (using owner for testing)
  ).send({ from: owner });
  console.log("Contract initialized");

  // --- Test: recordTrade ---
  await latContractInstance.methods.recordTrade(1000, true).send({ from: user1 });
  console.log("User1 recorded a trade of volume 1000");

  // --- Test: stakeLat ---
  // Mint some LAT tokens to user1. (Assumes MockLAT has a mint function.)
  await mockLATInstance.methods.mint(user1, web3.utils.toWei("100", "ether")).send({ from: owner });
  console.log("Minted 100 LAT to user1");
  
  // Approve the LiquidityAccelerationToken contract to spend tokens on behalf of user1.
  await mockLATInstance.methods.approve(latContractInstance.options.address, web3.utils.toWei("50", "ether")).send({ from: user1 });
  console.log("User1 approved 50 LAT for staking");
  
  // Stake 50 LAT tokens.
  await latContractInstance.methods.stakeLat(web3.utils.toWei("50", "ether")).send({ from: user1 });
  console.log("User1 staked 50 LAT");

  console.log("Test script completed.");
})();
