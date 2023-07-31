import { ethers, upgrades } from "hardhat";

async function main() {
  const V1contract = await ethers.getContractFactory("PicassoNFTMarketplaceV1");
  console.log("Deploying V1contract...");
  const v1contract = await upgrades.deployProxy(V1contract as any, [500, '0x2Bc598EcDEAbFb644EcC1904666c99e721e407Eb', '0x0b1ba0af832d7c05fd64161e0db78e85978e8082'], {
      initializer: "initialize",
  });
  await v1contract.waitForDeployment();
  console.log("V1 Contract deployed to:", await v1contract.getAddress());
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
