
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-deploy";
// upgradable plugin
import "@matterlabs/hardhat-zksync-upgradable";

import { HardhatUserConfig } from "hardhat/config";

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
  zksolc: {
    version: "latest",
    settings: {},
  },
  defaultNetwork: "zkSyncNetwork",
  networks: {
    goerli: {
      zksync: false,
      url: "http://localhost:8545",
    },
    zkSyncNetwork: {
      zksync: true,
      ethNetwork: "goerli",
      url: "https://mainnet.era.zksync.io",
    },
  },
};

export default config;