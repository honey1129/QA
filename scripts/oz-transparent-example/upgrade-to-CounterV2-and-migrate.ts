import { ethers, upgrades } from "hardhat";

const PROXY_ADDRESS = "<填入 Proxy 地址>";

async function main() {
    const CounterV2 = await ethers.getContractFactory("CounterV2");

    const counterV2 = await upgrades.upgradeProxy(PROXY_ADDRESS, CounterV2, {
        call: { fn: "migrate", args: [100] },
    });
    await counterV2.waitForDeployment();

    console.log("Upgraded & Migrated. Proxy:", await counterV2.getAddress());
    console.log(
        "countWithBonus =",
        (await counterV2.getFunction("countWithBonus")()).toString()
    );
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
