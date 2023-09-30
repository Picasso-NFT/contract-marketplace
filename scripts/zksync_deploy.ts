import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Wallet, Provider } from "zksync-web3";

import * as hre from "hardhat";

async function main() {
    const contractName = "PicassoNFTMarketplaceV1";
    console.log("Deploying " + contractName + "...");

    const zkWallet = new Wallet(process.env.PRIVATE_KEY as string);
    const deployer = new Deployer(hre, zkWallet);

    const contract = await deployer.loadArtifact(contractName);
    const box = await hre.zkUpgrades.deployProxy(deployer.zkWallet, contract, [200, '0x4B0eAB53e1D75d9261Aea1fdC6a849AE47Dce1EB'], { initializer: "initialize" });

    await box.deployed();
    console.log(contractName + " deployed to:", box.address);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});