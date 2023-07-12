import { ethers } from "hardhat";

async function main() {
  const PicasoFactory = await ethers.getContractFactory("PicasoFactory");
  const picasoFactory = await PicasoFactory.deploy();

  await picasoFactory.deployed();

  console.log(`deployed to ${picasoFactory.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
