import * as hre from "hardhat";

async function verify() {

    const verificationId = await hre.run("verify:verify", {
        address: '0x7FEA58089208f8AE3841D8C3dfD7d114bB880A4D',
    });
    console.log(verificationId);
}

verify();

