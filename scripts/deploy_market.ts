import { ethers, upgrades } from "hardhat";

const wNative = {
  goerli: '0x0b1ba0af832d7c05fd64161e0db78e85978e8082',
  polygon: '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270'
}

async function main() {
  const V1contract = await ethers.getContractFactory("PicassoNFTMarketplaceV1");
  console.log("Deploying V1contract...");
  const v1contract = await upgrades.deployProxy(
    V1contract as any, 
    [500, '0x2Bc598EcDEAbFb644EcC1904666c99e721e407Eb', wNative.polygon],
    {
      initializer: "initialize",
    }
  );
  await v1contract.waitForDeployment();
  console.log("V1 Contract deployed to:", await v1contract.getAddress());
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
