// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/* 下面以ERC721标准为例-严格的非同质化。如果你想让“同一个 ID 下面有多个数量的话”，可以采用ERC-1155。
如果单纯的考虑这个问题的话其实只要不限制tokenId的范围就好。uint256的足够大，实际场景中不可能达到极限。但实际上上线生产环境的话，要考虑许多其他问题。

* 在安全性上
1. 如果是非公开铸造，一定要设置相关的ADMIN权限和mint权限和burn权限，此处可以引入openzeppelin的AccessControl模块。
2. 把ADMIN权限交给多签钱包（Gnosis Safe/Timelock），而不是个人钱包，避免单点风险。
3. 如果是公开铸造的话，OG mint可以结合相关的白名单机制，增加限制mint的时间窗口。使用Merkle 树白名单机制。
   普通用户公开铸造可以使用EIP-712 签名机制（_MINT_TYPEHASH + usedSalt），防止用户直接通过合约mint，以及签名重放攻击。
4. 可以增加一个批量batchMint和batchBurn的方法，此时要注意限制输入的tokenID的范围，限制单笔规模。防止单笔交易超出区块 gas。
5. 同时增加一个控制的开关，防止出现异常时（私钥泄露、脚本失控等）能立刻关停。
6. 可以选择设计成可升级模式，防止合约上线后出现bug。

* 在安全性的基础上的gas优化，
1. 不要使用ERC721Enumerable，因为他是链上枚举的。每次 mint/transfer/burn 都要更新数组+索引映射，及其耗费gas。所以直接维护两个状态变量totalMinted，和totalBurned，计算totalSupply时直接totalMinted - totalBurned。
2. 不要使用ERC721URIStorage，因为它在每个 token 上链时，都要在合约存储里写一条 tokenId => string 映射，如果是无限增发，这个映射就会无限膨胀，链上状态越写越大。在查询tokenURI时直接用 baseURI() + tokenID 来拼接处URI。
*/

contract UnlimitedNFT is ERC721, ERC721Burnable, AccessControl, Pausable, ReentrancyGuard, EIP712 {

    // ---------- role ----------
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // ---------- constant/error ----------
    uint256 public constant MAX_BATCH_MINT = 50;

    error QuantityZeroOrTooLarge();
    error PriceMismatch();
    error Expired();
    error SaltUsed();
    error InvalidSigner();
    error NotWhitelisted();
    error WithdrawFailed();
    error NotOwnerNorApproved();

    // ---------- parameter ----------
    uint256 private _nextTokenId;
    uint256 public  totalMinted;
    uint256 public  totalBurned;
    uint256 public  mintPriceWei;
    string  private _baseTokenURI;

    // ---------- EIP-712 ----------
    bytes32 private constant _MINT_TYPEHASH = keccak256("Mint(address to,uint256 quantity,uint256 price,uint256 deadline,bytes32 salt)");
    mapping(bytes32 => bool) public usedSalt;

    // ---------- Merkle OG ----------
    // leaf：keccak256(abi.encodePacked(account, allowance))
    bytes32 public merkleRoot;
    mapping(address => uint32) public merkleMinted;

    // ---------- event ----------
    event Minted(address indexed to, uint256 indexed tokenId);
    event PublicMint(address indexed to, uint256 quantity, uint256 paid);
    event AdminBurned(uint256 indexed tokenId);
    event BaseURISet(string newBaseURI);
    event MintPriceSet(uint256 priceWei);
    event MerkleRootSet(bytes32 root);
    event PausedChanged(bool paused);


    // receive ETH
    receive() external payable {}

    fallback() external payable {}



    // ---------- constructor ----------
    constructor(string memory name_, string memory symbol_, string memory baseURI_, address admin_) ERC721(name_, symbol_) EIP712(name_, "1") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(MINTER_ROLE, admin_);
        _grantRole(SIGNER_ROLE, admin_);
        _baseTokenURI = baseURI_;
    }

    // ================= administrator operation =================
    function setBaseURI(string calldata newBase) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = newBase;
        emit BaseURISet(newBase);
    }

    function setMintPriceWei(uint256 price) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintPriceWei = price;
        emit MintPriceSet(price);
    }

    function setMerkleRoot(bytes32 root) external onlyRole(DEFAULT_ADMIN_ROLE) {
        merkleRoot = root;
        emit MerkleRootSet(root);
    }


    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {_pause();
        emit PausedChanged(true);}

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {_unpause();
        emit PausedChanged(false);}

    function withdraw(address payable to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "to=0");
        (bool ok,) = to.call{value: address(this).balance}("");
        if (!ok) revert WithdrawFailed();
    }

    // ================= readable function =================
    function totalSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ================= mint =================
    function mint(address to) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        unchecked {totalMinted += 1;}
        emit Minted(to, tokenId);
    }

    function mintBatch(address to, uint256 quantity) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 firstId){
        if (quantity == 0 || quantity > MAX_BATCH_MINT) revert QuantityZeroOrTooLarge();
        uint256 nextId = _nextTokenId;
        firstId = nextId;
        for (uint256 i; i < quantity;) {
            _safeMint(to, nextId++);
            emit Minted(to, nextId - 1);
            unchecked {++i;}
        }
        _nextTokenId = nextId;
        unchecked {totalMinted += quantity;}
    }

    // ================= public sale =================
    function mintPublic(uint256 quantity, uint256 price, uint256 deadline, bytes32 salt, bytes calldata sig) external payable whenNotPaused nonReentrant returns (uint256 firstId){
        if (quantity == 0 || quantity > MAX_BATCH_MINT) revert QuantityZeroOrTooLarge();
        if (block.timestamp > deadline) revert Expired();
        if (usedSalt[salt]) revert SaltUsed();
        if (price != mintPriceWei) revert PriceMismatch();
        if (msg.value != price * quantity) revert PriceMismatch();

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(_MINT_TYPEHASH, msg.sender, quantity, price, deadline, salt)));
        address signer = ECDSA.recover(digest, sig);
        if (!hasRole(SIGNER_ROLE, signer)) revert InvalidSigner();

        usedSalt[salt] = true;

        uint256 nextId = _nextTokenId;
        firstId = nextId;
        for (uint256 i; i < quantity;) {
            _safeMint(msg.sender, nextId++);
            emit Minted(msg.sender, nextId - 1);
            unchecked {++i;}
        }
        _nextTokenId = nextId;
        unchecked {totalMinted += quantity;}
        emit PublicMint(msg.sender, quantity, msg.value);
    }

    // ================= Merkle OG =================
    function mintMerkle(uint256 quantity, uint32 allowance, bytes32[] calldata proof) external payable whenNotPaused nonReentrant returns (uint256 firstId){
        if (merkleRoot == bytes32(0)) revert NotWhitelisted();
        if (quantity == 0 || quantity > MAX_BATCH_MINT) revert QuantityZeroOrTooLarge();
        if (msg.value != mintPriceWei * quantity) revert PriceMismatch();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, allowance));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert NotWhitelisted();

        uint32 used = merkleMinted[msg.sender];
        if (used + quantity > allowance) revert QuantityZeroOrTooLarge();
        merkleMinted[msg.sender] = used + uint32(quantity);

        uint256 nextId = _nextTokenId;
        firstId = nextId;
        for (uint256 i; i < quantity;) {
            _safeMint(msg.sender, nextId++);
            emit Minted(msg.sender, nextId - 1);
            unchecked {++i;}
        }
        _nextTokenId = nextId;
        unchecked {totalMinted += quantity;}
    }

    // ================= adminBurn =================
    function adminBurn(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _burn(tokenId);
        emit AdminBurned(tokenId);
    }

    // ============== burnBatch（owner/approved） ==============
    function burnBatch(uint256[] calldata tokenIds) external whenNotPaused {
        uint256 n = tokenIds.length;
        for (uint256 i = 0; i < n; ) {
            uint256 id = tokenIds[i];

            address owner = _ownerOf(id);
            if (!_isAuthorized(owner, msg.sender, id)) revert NotOwnerNorApproved();

            _burn(id);
            unchecked { ++i; }
        }
    }

    // ================= hook  =================
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from){
        from = super._update(to, tokenId, auth);
        if (to == address(0)) {
            unchecked {totalBurned += 1;}
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool){
        return super.supportsInterface(interfaceId);
    }


}
