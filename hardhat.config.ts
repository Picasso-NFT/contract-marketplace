
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-deploy";
// upgradable plugin
import "@matterlabs/hardhat-zksync-upgradable";
import "@nomicfoundation/hardhat-verify";
import "@matterlabs/hardhat-zksync-verify";

import { HardhatUserConfig } from "hardhat/config";
import 'dotenv/config'

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
  zksolc: {
    version: "latest",
    settings: {},
  },
  defaultNetwork: "zkSyncTest",
  networks: {
    // goerli: {
    //   zksync: false,
    //   url: process.env.RPC_URL as string,
    //   accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    // },
    // polygon: {
    //   zksync: false,
    //   url: 'https://polygon-mainnet.g.alchemy.com/v2/IJTBGfiQOweNEKXDTQ9jdH5I8fzyXPyt',
    //   accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    // },
    zkSyncTest: {
      zksync: true,
      ethNetwork: "goerli",
      url: "https://zksync2-testnet.zksync.dev",
      verifyURL: 'https://zksync2-testnet-explorer.zksync.dev/contract_verification'
    },
    zkSync: {
      zksync: true,
      ethNetwork: "mainnet",
      url: "https://mainnet.era.zksync.io",
      verifyURL: 'https://zksync2-mainnet-explorer.zksync.io/contract_verification'
    },
  },
  mocha: {
    timeout: 20000
  }
};

export default config;