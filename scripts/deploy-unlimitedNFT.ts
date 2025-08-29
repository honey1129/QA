import { ethers, run } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
    const name = process.env.NFT_NAME || "UnlimitedNFT";
    const symbol = process.env.NFT_SYMBOL || "UNL";
    const baseURI = process.env.BASE_URI || "https://example.com/meta/";
    const admin = process.env.ADMIN || "";
    const mintPriceWeiStr = process.env.MINT_PRICE_WEI ?? "";
    if (!admin) throw new Error("ADMIN not set in .env");

    console.log("Deploy params:");
    console.log({ name, symbol, baseURI, admin });

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const UnlimitedNFT = await ethers.getContractFactory("UnlimitedNFT");
    const contract = await UnlimitedNFT.deploy(name, symbol, baseURI, admin);
    await contract.waitForDeployment();

    const addr = await contract.getAddress();
    const hash = contract.deploymentTransaction()?.hash;
    console.log(`\n✅ Deployed UnlimitedNFT at: ${addr}`);
    if (hash) console.log(`   Tx: ${hash}`);


    if (mintPriceWeiStr !== "") {
        const price = BigInt(mintPriceWeiStr);
        const tx = await contract.setMintPriceWei(price);
        console.log(`Setting mintPriceWei = ${price} ... tx=${tx.hash}`);
        await tx.wait();
        console.log("✅ mintPriceWei set");
    }

    console.log("\nNext steps:");
    console.log(`- grantRole MINTER_ROLE/SIGNER_ROLE and setMerkleRoot`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
