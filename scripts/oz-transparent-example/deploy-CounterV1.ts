import { ethers, upgrades } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const CounterV1 = await ethers.getContractFactory("CounterV1");

    // 部署 Transparent Proxy，自动创建 ProxyAdmin 并调用 initialize
    const counter = await upgrades.deployProxy(
        CounterV1,
        [deployer.address, 42],
        { initializer: "initialize", kind: "transparent" }
    );
    await counter.waitForDeployment();
    console.log("Proxy (Counter) deployed to:", await counter.getAddress());

    const impl = await upgrades.erc1967.getImplementationAddress(await counter.getAddress());
    const admin = await upgrades.erc1967.getAdminAddress(await counter.getAddress());
    console.log("Implementation (V1):", impl);
    console.log("Proxy Admin:", admin);


    console.log("count =", (await counter.getFunction("count")()).toString());
    await (await counter.getFunction("inc")()).wait();
    console.log("count after inc =", (await counter.getFunction("count")()).toString());
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
