require("dotenv").config();
require("@nomicfoundation/hardhat-ethers");

const { BSC_RPC_URL, PRIVATE_KEY } = process.env;

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    bsc: {
      url: BSC_RPC_URL || "",
      chainId: 56,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
};
