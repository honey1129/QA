// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract NFTMarket is EIP712, ReentrancyGuard, Ownable {

    using ECDSA for bytes32;

    // ---------- error ----------
    error TimeWindow();
    error ReservedBuyerOnly();
    error ReservedSellerOnly();
    error BadAskSig();
    error BadBidSig();
    error NonceUsed();
    error BadMsgValue();
    error BidMustUseERC20();
    error FeeTooHigh();
    error ZeroFeeRecipient();
    error FeePlusRoyaltyExceedPrice();
    error ERC20PullFailed();
    error ERC20PayFailed();

    // ---------- parameter ----------
    uint256 public feeBps;
    address public feeRecipient;
    mapping(address => mapping(uint256 => uint256)) private _nonceBitmap;

    // ---------- EIP-712 ----------
    bytes32 private constant ASK_TYPEHASH = keccak256("Ask(address signer,address collection,uint256 tokenId,address currency,uint256 price,uint256 startTime,uint256 endTime,uint256 nonce,address reservedBuyer)");
    bytes32 private constant BID_TYPEHASH = keccak256("Bid(address signer,address collection,uint256 tokenId,address currency,uint256 price,uint256 startTime,uint256 endTime,uint256 nonce,address reservedSeller)");

    struct Ask {
        uint256 tokenId;
        address currency;
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        uint256 nonce;
        address reservedBuyer;
        address signer;
        address collection;
    }

    struct Bid {
        uint256 tokenId;
        address currency;
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        uint256 nonce;
        address reservedSeller;
        address signer;
        address collection;
    }

    event Trade(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed currency,
        uint256 price,
        address seller,
        address buyer,
        uint256 fee,
        address royaltyReceiver,
        uint256 royaltyAmount,
        bytes32 orderHash,
        bool isBid
    );


    // receive ETH
    receive() external payable {}

    fallback() external payable {}


    constructor(uint256 _feeBps, address _feeRecipient)EIP712("NFTMarket", "1"){
        if (_feeRecipient == address(0)) revert ZeroFeeRecipient();
        if (_feeBps > 1000) revert FeeTooHigh();
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }

    // ---------- Admin ----------
    function setFee(uint256 _feeBps, address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroFeeRecipient();
        if (_feeBps > 1000) revert FeeTooHigh();
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }


    function cancel(uint256[] calldata nonces) external {
        for (uint256 i; i < nonces.length; ++i) {
            _useNonce(msg.sender, nonces[i]);
        }
    }

    // ---------- buy----------
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

        emit Trade(
            a.collection,
            a.tokenId,
            a.currency,
            a.price,
            a.signer,
            to,
            fee,
            rcv,
            roy,
            _hashAsk(a),
            false
        );    }

    // ---------- acceptBid----------
    function acceptBid(Bid calldata b, bytes calldata sig, address to) external nonReentrant {
        _checkWindow(b.startTime, b.endTime);
        if (b.currency == address(0)) revert BidMustUseERC20();
        _verifyBidSig(b, sig);
        if (b.reservedSeller != address(0) && msg.sender != b.reservedSeller) revert ReservedSellerOnly();
        _useNonce(b.signer, b.nonce);

        IERC721(b.collection).safeTransferFrom(msg.sender, to, b.tokenId);

        if (!_erc20TransferFrom(b.currency, b.signer, address(this), b.price)) revert ERC20PullFailed();

        (uint256 fee, address rcv, uint256 roy, uint256 sellerProceeds) = _split(b.collection, b.tokenId, b.price);

        _payout(b.currency, rcv, roy);
        _payout(b.currency, feeRecipient, fee);
        _payout(b.currency, msg.sender, sellerProceeds);

        emit Trade(
            b.collection,
            b.tokenId,
            b.currency,
            b.price,
            msg.sender,
            to,
            fee,
            rcv,
            roy,
            _hashBid(b),
            true
        );    }

    // ---------- Internal Helpers ----------
    function _split(address collection, uint256 tokenId, uint256 price) internal view returns (uint256 fee, address r, uint256 roy, uint256 sellerProceeds){
        fee = (price * feeBps) / 10_000;

        (bool ok, bytes memory data) = collection.staticcall(abi.encodeWithSelector(IERC2981.royaltyInfo.selector, tokenId, price));
        if (ok && data.length >= 64) {
            (r, roy) = abi.decode(data, (address, uint256));
        }

        if (fee + roy > price) revert FeePlusRoyaltyExceedPrice();
        sellerProceeds = price - fee - roy;
    }

    function _payout(address currency, address to, uint256 amount) internal {
        if (amount == 0 || to == address(0)) return;
        if (currency == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            if (!_erc20Transfer(currency, to, amount)) revert ERC20PayFailed();
        }
    }

    function _checkWindow(uint256 s, uint256 e) internal view {
        if (!(block.timestamp >= s && block.timestamp <= e)) revert TimeWindow();
    }

    function _useNonce(address signer, uint256 nonce) internal {
        uint256 word = nonce >> 8;
        uint256 mask = uint256(1) << (nonce & 255);
        uint256 val  = _nonceBitmap[signer][word];
        if ((val & mask) != 0) revert NonceUsed();
        _nonceBitmap[signer][word] = val | mask;
    }

    // ---------- ERC20 ----------
    function _erc20TransferFrom(address token, address from, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _erc20Transfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    // ---------- EIP-712 ----------
    function _hashAsk(Ask calldata a) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            ASK_TYPEHASH,
            a.signer, a.collection, a.tokenId, a.currency, a.price,
            a.startTime, a.endTime, a.nonce, a.reservedBuyer
        )));
    }
    function _hashBid(Bid calldata b) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            BID_TYPEHASH,
            b.signer, b.collection, b.tokenId, b.currency, b.price,
            b.startTime, b.endTime, b.nonce, b.reservedSeller
        )));
    }
    function _verifyAskSig(Ask calldata a, bytes calldata sig) internal view {
        if (_hashAsk(a).recover(sig) != a.signer) revert BadAskSig();
    }
    function _verifyBidSig(Bid calldata b, bytes calldata sig) internal view {
        if (_hashBid(b).recover(sig) != b.signer) revert BadBidSig();
    }

}
