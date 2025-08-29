import { ethers, run } from "hardhat";

async function main() {
    const feeBps = parseInt(process.env.FEE_BPS || "250", 10); // 2.5%
    const feeRecipient = process.env.FEE_RECIPIENT!;
    if (!ethers.isAddress(feeRecipient)) {
        throw new Error("Invalid FEE_RECIPIENT");
    }

    console.log(`Deploying NFTMarket with feeBps=${feeBps}, feeRecipient=${feeRecipient}`);

    const Factory = await ethers.getContractFactory("NFTMarket");
    const contract = await Factory.deploy(feeBps, feeRecipient);
    await contract.waitForDeployment();

    const addr = await contract.getAddress();
    const hash = contract.deploymentTransaction()?.hash;
    console.log(`NFTMarket deployed to: ${addr}`);
    console.log(`tx: ${hash}`);

}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
