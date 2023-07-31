const { ethers, upgrades } = require("hardhat");

async function main() {
  const upgrade = await ethers.getContractFactory("PICAMarketplaceV2");
  const instance = await upgrades.upgradeProxy('0x9000c5adf531b149e5aaabb25e925d7c03950a7a', upgrade);
  console.log("Box upgraded: " + instance.address);
}

main();