import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Wallet, Provider } from "zksync-web3";

import * as hre from "hardhat";

const WETH = '0x5aea5775959fbc2557cc8789bc1bf90a239d9a91';

// const WETH = '0x5aea5775959fbc2557cc8789bc1bf90a239d9a91';

async function main() {
    const contractName = "PicassoNFTMarketplaceV1";
    console.log("Deploying " + contractName + "...");

    const zkWallet = new Wallet(process.env.PRIVATE_KEY as string);
    const deployer = new Deployer(hre, zkWallet);

    const contract = await deployer.loadArtifact(contractName);
    const box = await hre.zkUpgrades.deployProxy(deployer.zkWallet, contract, [200, '0x4B0eAB53e1D75d9261Aea1fdC6a849AE47Dce1EB', WETH], { initializer: "initialize" });

    await box.deployed();
    console.log(contractName + " deployed to:", box.address);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});