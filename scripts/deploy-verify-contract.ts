import { ethers, run, network } from "hardhat";

async function sleep(ms: number) {
    return new Promise((res) => setTimeout(res, ms));
}

async function main() {
    const constructorArg = "Hello, scanner!";
    const confirmations = 2;

    console.log(`Network: ${network.name}`);

    const Hello = await ethers.getContractFactory("Hello");
    const hello = await Hello.deploy(constructorArg);
    await hello.waitForDeployment();
    const addr = await hello.getAddress();
    console.log("Hello deployed to:", addr);

    if (confirmations > 0) {
        console.log(`Waiting for ${confirmations} block confirmations...`);
        const tx = hello.deploymentTransaction();
        if (tx?.hash) {
            await ethers.provider.waitForTransaction(tx.hash, confirmations);
        } else {
            await sleep(10_000);
        }
    } else {
        await sleep(8_000);
    }

    try {
        console.log("Verifying on explorer...");
        await run("verify:verify", {
            address: addr,
            constructorArguments: [constructorArg],
        });
        console.log("✅ Verify success");
    } catch (e: any) {
        const msg: string = e?.message || String(e);
        if (/Already Verified/i.test(msg) || /Contract source code already verified/i.test(msg)) {
            console.log("ℹ️  Already verified, skipping.");
        } else {
            console.error("❌ Verify failed:", msg);
            console.log("Retrying after 15s...");
            await sleep(15_000);
            try {
                await run("verify:verify", {
                    address: addr,
                    constructorArguments: [constructorArg],
                });
                console.log("✅ Verify success (retry)");
            } catch (e2: any) {
                console.error("❌ Verify failed (retry):", e2?.message || String(e2));
            }
        }
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
