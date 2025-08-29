# 1. 你能写一个支持无限增发和销毁的 NFT 合约吗？请简单描述合约的核心设计思路
下面以ERC721标准为例-严格的非同质化。如果你想让“同一个 ID 下面有多个数量的话”，可以采用ERC-1155。
如果单纯的考虑这个问题的话其实只要不限制tokenId的范围就好。uint256的足够大，实际场景中不可能达到极限。但实际上上线生产环境的话，要考虑许多其他问题。

* 在安全性上
1. 如果是非公开铸造，一定要设置相关的ADMIN权限和mint权限和burn权限，此处可以引入openzeppelin的AccessControl模块。
2. 把ADMIN权限交给多签钱包（Gnosis Safe/Timelock），而不是个人钱包，避免单点风险。
3. 如果是公开铸造的话，OG mint可以结合相关的白名单机制，增加限制mint的时间窗口。使用Merkle 树白名单机制。
   普通用户公开铸造可以使用EIP-712 签名机制（_MINT_TYPEHASH + usedSalt），防止用户直接通过合约mint，以及签名重放攻击。
4. 可以增加一个批量batchMint和batchBurn的方法，此时要注意限制输入的tokenID的范围，限制单笔规模。防止单笔交易超出区块 gas。
5. 同时增加一个控制的开关，防止出现异常时（私钥泄露、脚本失控等）能立刻关停。
6. 要时可以选择设计成可升级模式，防止合约上线后出现bug。

* 在安全性的基础上的gas优化，
1. 不要使用ERC721Enumerable，因为他是链上枚举的。每次 mint/transfer/burn 都要更新数组+索引映射，及其耗费gas。所以直接维护两个状态变量totalMinted，和totalBurned，计算totalSupply时直接totalMinted - totalBurned。
2. 不要使用ERC721URIStorage，因为它在每个 token 上链时，都要在合约存储里写一条 tokenId => string 映射，如果是无限增发，这个映射就会无限膨胀，链上状态越写越大。在查询tokenURI时直接用 baseURI() + tokenID 来拼接处URI。



# 2.如果要实现一个用户之间 NFT 交易的合约（支持 ETH 和 ERC20 支付），平台会收取手续费，你会怎么设计？
NFT 交易市场的设计分链上和链下部分，订单数据、签名、撮合与检索都是放在链下完成，而链上只负责资产交割的部分，这是大部分非托管式NFT market的设计。
而链上的NFT交易分卖家挂单买家吃单buy过程以及买家挂单卖家吃单acceptBid过程，这些所有的交易信息可以在链上用一个struct包装，相关变量的设置：

```solidity
struct Ask {
   uint256 tokenId;              // 卖家要出售的 NFT 的 tokenId
   address currency;             // 支付币种：0 地址表示 ETH，否则是某个 ERC20 合约地址
   uint256 price;                // 出售价格（总价，不是单价）总是代表currency的数量。
   uint256 startTime;            // 订单生效时间（区块时间戳 >= startTime 才能成交）
   uint256 endTime;              // 订单过期时间（区块时间戳 <= endTime 才能成交）
   uint256 nonce;                // 卖家的订单编号，用于防重放和取消
   address reservedBuyer;        // 定向买家：如果非 0 地址，则只有这个地址能成交
   address signer;               // 卖家地址（签署这个订单的人）
   address collection;           // NFT 合约地址
}
```
1. 卖家挂单买家吃单 buy的流程

   ```solidity
     function buy(Ask calldata a, bytes calldata sig, address to) external payable nonReentrant {
   _checkWindow(a.startTime, a.endTime);
   _verifyAskSig(a, sig);
   if (a.reservedBuyer != address(0) && msg.sender != a.reservedBuyer) revert ReservedBuyerOnly();
   _useNonce(a.signer, a.nonce);
    
    if (a.currency == address(0)) {
        if (msg.value != a.price) revert BadMsgValue();
    } else {
        if (msg.value != 0) revert BadMsgValue();
        if (!_erc20TransferFrom(a.currency, msg.sender, address(this), a.price)) revert ERC20PullFailed();
    }
   
    (uint256 fee, address rcv, uint256 roy, uint256 sellerProceeds) = _split(a.collection, a.tokenId, a.price);
   
    IERC721(a.collection).safeTransferFrom(a.signer, to, a.tokenId);
   
   
    _payout(a.currency, rcv, roy);
    _payout(a.currency, feeRecipient, fee);
    _payout(a.currency, a.signer, sellerProceeds);
   
    emit Trade(_hashAsk(a), false, a.collection, a.tokenId, a.currency, a.price, a.signer, to, fee, rcv, roy);}
   ```
   后端服务撮合交易找到满足卖家条件的买家，此时后端调用合约执行买家吃卖单 buy的流程。
   1. a 是卖单的Ask结构体数据、sig 是卖家对卖单的 EIP-712 签名，这部分是从后端获取的，to 是 NFT 最终接收地址。
   2. 校验时间窗，当前时间必须落在 卖家设置的[startTime, endTime]
   3. 验签：用 EIP-712 恢复签名者并要求等于 a.signer
   4. 定向单校验：若 reservedBuyer 非 0，则只允许该地址吃单
   5. 收款：
      * 如果币种是 ETH（address(0)）：要求本次调用携带的 msg.value 恰好等于 price
      * 如果是 ERC20：要求本次调用 不带 ETH（msg.value == 0），并从买家msg.sender地址转移price对应数量的ERC20Token到合约
   6. 分红计算（只是计算校验）：
      * fee = price * feeBps / 10_000（平台费）
      * 版税 (rcv, roy) = royaltyInfo(tokenId, price)（不支持则 0）
      * 校验 fee + roy ≤ price
      * 卖家到手 sellerProceeds = price - fee - roy
   7. 交割NFT
      * IERC721(a.collection).safeTransferFrom(a.signer, to, a.tokenId);
      * 将NFT从卖家地址转移到NFT的接受地址。
      * 要求卖家挂单时已将NFT setApprovalForAll给合约。这一步可在前端执行挂单时提示用户执行。
   8. 分红计算
      * _payout(a.currency, rcv, roy); 收取版税（可选）
      * _payout(a.currency, feeRecipient, fee);收取平台费用
      * _payout(a.currency, a.signer, sellerProceeds); 剩余资金转移给卖家。
   9. 记录相关event 方便索引，统计。

2. 买家挂单卖家吃单acceptBid过程和卖家挂单买家吃单 buy的流程的关键步骤基本相同
不过最主要的是卖家的支付币种必须是ERC20代币，如果想用ETH则必须使用WETH
这一步前端可以买家“出价”时引导买家：先用WETH.deposit 把 ETH 变 WETH 然后再approve 给合约。

# 3、是否写过 OpenZeppelin Transparent Proxy ，简述部署流程和合约升级流程。
1. OpenZeppelin的Transparent升级模式，包括三部分合约
   * ProxyAdmin
   * TransparentUpgradeableProxy
   * implementation
   其中ProxyAdmin和 TransparentUpgradeableProxy是OpenZeppelin预设好的，只需关注implementation合约的编写就好。
   implementation合约的编写和普通合约有所不同。
   * 不能使用contractor构造函数，使用initialize + initializer函数限定符来取代构造函数
   * 使用 @openzeppelin/contracts-upgradeable库而不是使用 @openzeppelin/contracts合约库
   * 不能改动既有变量的顺序、类型或删除变量；只能在末尾追加新变量
   * 运行时的 address(this)、合约余额等都属于Proxy，不是implementation合约。

2. 部署流程和合约升级流程可以使用hardhat的插件来完成

   1. 部署

   ```typescript
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
   ```
   2. 升级
   ```typescript
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
   ```

2. 部署流程和合约升级流程完全手动来完成     
   1. 手动部署
      1. 部署Implementation实现合约
      2. 部署 ProxyAdmin
      3. 用脚本计算出初始化数据
         const initData = Implementation.interface.encodeFunctionData("initialize", [参数1，参数2]);
      4. 部署 TransparentUpgradeableProxy(implementation, admin, initData)
   2. 手动升级
      1. 部署新编写好的Implementation实现合约
      2. 调用ProxyAdmin合约的upgrade(proxy, newImplementation)
   
# 4. 你平时是怎么在区块浏览器（Etherscan，basescan，bscscan，等）上 verify 合约的？
一般来说使用插件自动验证是最方便和快速的。
  1. 安装插件：
     npm install --save-dev @nomicfoundation/hardhat-verify
  2. 在 hardhat.config.ts 里配置 API key：
   etherscan: {
         apiKey: {
               bsc: process.env.BSCSCAN_API_KEY!,
               mainnet: process.env.ETHERSCAN_API_KEY!,
               base: process.env.BASESCAN_API_KEY!,
            }
         }
  3. 执行验证 
   运行指令 npx hardhat verify --network bsc 0xYourContractAddress "constructorArg1" "constructorArg2"
