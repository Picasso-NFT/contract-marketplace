const { ethers, upgrades } = require("hardhat");

async function main() {
  const upgrade = await ethers.getContractFactory("PicassoNFTMarketplaceV1");
  const instance = await upgrades.upgradeProxy('0x55bcbfd402fd43db5fb0961bd6acbeaf831e4ca8', upgrade);
  console.log("Box upgraded: " + instance.address);
}

main();