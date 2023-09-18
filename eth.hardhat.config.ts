import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import 'dotenv/config';
import '@openzeppelin/hardhat-upgrades';
// import "@matterlabs/hardhat-zksync-deploy";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  paths: {
    sources: "contracts"
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {},
    localhost: {
      url: "http://127.0.0.1:8545"
    },
    goerli: {
      url: process.env.RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    polygon: {
      url: 'https://polygon-mainnet.g.alchemy.com/v2/IJTBGfiQOweNEKXDTQ9jdH5I8fzyXPyt',
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    zksync: {
      url: 'https://mainnet.era.zksync.io',
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      // zksync: true
    }
  },
  etherscan: {
    apiKey: {
      goerli: process.env.ETHERSCAN_API_KEY as string,
      polygon: process.env.POLYGON_API_KEY as string,
    } 
  },
  mocha: {
    timeout: 20000
  }
};

export default config;
