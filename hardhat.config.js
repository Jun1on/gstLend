require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.19",
      },
      {
        version: "0.8.12",
      },
    ],
  },
  networks: {

    hardhat: {
      chainId: 42161,
      forking: {
        url: "https://arb1.arbitrum.io/rpc",
        enabled: true
      },
      gasPrice: 2000000000,
    },
  },
};