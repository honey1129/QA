## 1.安装依赖
`npm install `

## 2.配置 .env 文件
`copy .env.example .env`

## 3.部署合约到sepolia测试网
1. 部署deploy-NFTMarket合约到测试网
`npx hardhat run scripts/deploy-NFTMarket.ts --network sepolia`
2. 部署deploy-unlimitedNFT合约到测试网
`npx hardhat run scripts/deploy-unlimitedNFT.ts --network sepolia`
3. 部署counterV1可升级合约到测试网
`npx hardhat run scripts/oz-transparent-example/deploy-CounterV1.ts --network sepolia`
4. 升级counterV1合约
`npx hardhat run scripts/oz-transparent-example/upgrade-to-CounterV2-and-migrate.ts --network sepolia`
5. 部署并验证示例合约
`npx hardhat run scripts/deploy-verify-contract.ts --network sepolia`

