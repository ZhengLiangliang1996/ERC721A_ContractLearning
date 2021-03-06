// Copyright © 2022 liangliang <liangliang@Liangliangs-MacBook-Air.local>
//
// Distributed under terms of the MIT license.

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";            // 基础权限管理
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";  // 防止重复/嵌套使用
import "./ERC721A.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/*
* Some configuration and modifier
*/

contract Azuki is Ownable, ERC721A, ReentrancyGuard {
  // Some immutable variable
  uint256 public immutable maxPerAddressDuringMint; // 单个地址可mint次数
  uint256 public immutable amountForDevs;
  uint256 public immutable amountForAuctionAndDev;

  struct SaleConfig {
    // Configuration of sale
    uint32 auctionSaleStartTime;
    uint32 publicSaleStartTime;
    uint64 mintlistPrice;
    uint64 publicPrice;
    uint32 publicSaleKey; // 执行发售合约的owner address
  }

  SaleConfig public saleConfig;

  // Use mapping(address => uint256) to record the minting balance of every whitelist
  mapping(address => uint256) public allowlist;


// Constructor is a special function that is only executed upon contract creation. 
// You can run the contract initialization code.

  constructor(
    uint256 maxBatchSize_,    // the explanation at last
    uint256 collectionSize_,  // the max supply of the NFT
    uint256 amountForAuctionAndDev_,
    uint256 amountForDevs_
  ) ERC721A("Azuki", "AZUKI", maxBatchSize_, collectionSize_) { 
      // “Azuki” is the NFT token name
      // “AZUKI” is the token symbol
    maxPerAddressDuringMint = maxBatchSize_;
    amountForAuctionAndDev = amountForAuctionAndDev_;
    amountForDevs = amountForDevs_;
    require(
      amountForAuctionAndDev_ <= collectionSize_,
      "larger collection size needed"
    );
  }
  
  /*
  uint256 maxBatchSize_
    + defining the maximum NFT a minter can mint in `_safeMint()` in ERC721A
    + using in `ownershipOf()` to check tokenId of the owner in ERC721A
    + amount of `devMint()` needed to be a multiply of it
    + the maximum of NFT every address when auction mint and public sale
  */

  // Before calling mint function, check if the caller is the user rather than other contracts.
  modifier callerIsUser() {
    require(tx.origin == msg.sender, "The caller is another contract");
    _;
  }

  // The mint function used for auction
  function auctionMint(uint256 quantity) external payable callerIsUser {   // 3 Mint
    uint256 _saleStartTime = uint256(saleConfig.auctionSaleStartTime);
    // It can mint when the auction begins.
    require(
      _saleStartTime != 0 && block.timestamp >= _saleStartTime,
      "sale has not started yet"
    );
    // The sum of the minted amount and the quantity of caller inputs needs to be lower than the supply for auction and dev.
    require(
      totalSupply() + quantity <= amountForAuctionAndDev,
      "not enough remaining reserved for auction to support desired mint amount"
    );
    // The sum of the quantity caller inputs and the balance of NFT in the wallet should be lower than the max balance for every address during mint.
    require(
      numberMinted(msg.sender) + quantity <= maxPerAddressDuringMint,
      "can not mint this many"
    );
    
    // Get the minting cost. Whenever it checks the auction price at the moment, 
    // it sends the set public variable _saleStartTime to the function getAuctionPrice() to confirm whether the auction has started or not.
    
    uint256 totalCost = getAuctionPrice(_saleStartTime) * quantity;
    _safeMint(msg.sender, quantity);    // Use the ERC721A function `_safeMint`
    refundIfOver(totalCost);            // Return the money if it's extra.
  }
  
  /*
  * The mint function for the whitelisted
  */
  
  function allowlistMint() external payable callerIsUser {                  // 2 权限判断 Authentication Part 
    uint256 price = uint256(saleConfig.mintlistPrice);                      // price of those are eligible to mint 
    require(price != 0, "allowlist sale has not begun yet");                // sanity check if the mint for whitelists is begins.
    // allowList map address -> unit256 [number of slots]
    require(allowlist[msg.sender] > 0, "not eligible for allowlist mint");
    // `totalSupply()` returns the length of the minted tokens
    require(totalSupply() + 1 <= collectionSize, "reached max supply");     // check maximum supply 
    // Before caller call `_safeMint()`, it minus one in the amount of this whitelist can mint
    allowlist[msg.sender]--;      // decrease one 
    _safeMint(msg.sender, 1);     // It mints one NFT everytime. // safe mint see in ERC721A.sol  
    refundIfOver(price);          // refund surplus or ask to have more ETH
  }

/*
* The mint function for the public sale
*/

  function publicSaleMint(uint256 quantity, uint256 callerPublicSaleKey)
    external
    payable
    callerIsUser
  {                                                                          // 3 Mint
    SaleConfig memory config = saleConfig;
    uint256 publicSaleKey = uint256(config.publicSaleKey);
    uint256 publicPrice = uint256(config.publicPrice);
    uint256 publicSaleStartTime = uint256(config.publicSaleStartTime);
    // Need the correct key for the public sale
    require(
      publicSaleKey == callerPublicSaleKey,
      "called with incorrect public sale key"
    );
    // Check if the public sale starts
    require(
      isPublicSaleOn(publicPrice, publicSaleKey, publicSaleStartTime),
      "public sale has not begun yet"
    );
    require(totalSupply() + quantity <= collectionSize, "reached max supply");
    require(
      numberMinted(msg.sender) + quantity <= maxPerAddressDuringMint,
      "can not mint this many"
    );
    _safeMint(msg.sender, quantity);
    refundIfOver(publicPrice * quantity);
  }

  // The function of returning the excess money
  function refundIfOver(uint256 price) private {                             // 3 Mint
    require(msg.value >= price, "Need to send more ETH.");
    if (msg.value > price) {
      payable(msg.sender).transfer(msg.value - price);
    }
  }
  
  // check if the public sale is already happens 
  // Anyone can check if the public sale starts
  function isPublicSaleOn(                                                   // 2 权限判断 Authentication Part 
    uint256 publicPriceWei, //
    uint256 publicSaleKey, // 
    uint256 publicSaleStartTime // 
  ) public view returns (bool) {
    return
      publicPriceWei != 0 &&
      publicSaleKey != 0 &&
      block.timestamp >= publicSaleStartTime;
  }

/*
* Auction mint and set up information of sale after the auction
*/

// Some configuration of the auction
// Dutch auction starts at some high price and reduces the price with time passing by

  uint256 public constant AUCTION_START_PRICE = 1 ether;
  uint256 public constant AUCTION_END_PRICE = 0.15 ether;
  uint256 public constant AUCTION_PRICE_CURVE_LENGTH = 340 minutes;
  uint256 public constant AUCTION_DROP_INTERVAL = 20 minutes;
  uint256 public constant AUCTION_DROP_PER_STEP =
    (AUCTION_START_PRICE - AUCTION_END_PRICE) /
      (AUCTION_PRICE_CURVE_LENGTH / AUCTION_DROP_INTERVAL); //the reducing extent of every step

  // Anyone can get the so-far price of the auction
  function getAuctionPrice(uint256 _saleStartTime)
    public
    view
    returns (uint256)
  {
    if (block.timestamp < _saleStartTime) {
      return AUCTION_START_PRICE;
    }
    if (block.timestamp - _saleStartTime >= AUCTION_PRICE_CURVE_LENGTH) {
      return AUCTION_END_PRICE;
    } else {
      uint256 steps = (block.timestamp - _saleStartTime) /
        AUCTION_DROP_INTERVAL;
      return AUCTION_START_PRICE - (steps * AUCTION_DROP_PER_STEP);
    }
  }

  // End the auction and setup some sale information about the price for `allowlist` and the public sale
  function endAuctionAndSetupNonAuctionSaleInfo(
    uint64 mintlistPriceWei,
    uint64 publicPriceWei,
    uint32 publicSaleStartTime
  ) external onlyOwner {
    saleConfig = SaleConfig(
      0,
      publicSaleStartTime,
      mintlistPriceWei,
      publicPriceWei,
      saleConfig.publicSaleKey
    );
  }

  // Decide when the auction starts
  function setAuctionSaleStartTime(uint32 timestamp) external onlyOwner { // 拍卖开始时间
    saleConfig.auctionSaleStartTime = timestamp;
  }

  // Set the key for the public sale
  function setPublicSaleKey(uint32 key) external onlyOwner {              // 执行公开销售的owner address
    saleConfig.publicSaleKey = key;
  }

  // Set the whitelisted address and the amount they can mint
  function seedAllowlist(address[] memory addresses, uint256[] memory numSlots)
    external
    onlyOwner
  {
    require(
      addresses.length == numSlots.length,
      "addresses does not match numSlots length"
    );
    for (uint256 i = 0; i < addresses.length; i++) {
      allowlist[addresses[i]] = numSlots[i];
    }
  }

/*
* Free mint (for marketing etc)
*/

  function devMint(uint256 quantity) external onlyOwner {                 // 3 Mint
  
    // The sum of the minted amount and the input needs to be lower than amount for dev.
    require(
      totalSupply() + quantity <= amountForDevs,
      "too many already minted before dev mint"
    );
    
    // The input has to be a positive multiply of the `maxBatchSize`
    require(
      quantity % maxBatchSize == 0,
      "can only mint a multiple of the maxBatchSize"
    );
    
    // The logic of reducing the minting gas
    uint256 numChunks = quantity / maxBatchSize;
    for (uint256 i = 0; i < numChunks; i++) {
      _safeMint(msg.sender, maxBatchSize);
    }
  }

/* 
* metadata URI
*/ 
  string private _baseTokenURI;

  function _baseURI() internal view virtual override returns (string memory) {
    return _baseTokenURI;
  }

  function setBaseURI(string calldata baseURI) external onlyOwner {
    _baseTokenURI = baseURI;
  }

  // withdraw the money in NFT contract to the owner address
  // use `nonReentrant` to protect from the reentrancy attack
  function withdrawMoney() external onlyOwner nonReentrant {
    (bool success, ) = msg.sender.call{value: address(this).balance}("");
    require(success, "Transfer failed.");
  }

  // For the logic of ERC721A, explicitly set `owners` to eliminate loops in future calls of `ownerOf()`.
  function setOwnersExplicit(uint256 quantity) external onlyOwner nonReentrant {
    _setOwnersExplicit(quantity);
  }

  // Check how many NFT this address owns
  function numberMinted(address owner) public view returns (uint256) {
    return _numberMinted(owner);
  }

  // It will return who owns this token and the timestamp he or she owns it.
  function getOwnershipData(uint256 tokenId)
    external
    view
    returns (TokenOwnership memory)
  {
    return ownershipOf(tokenId);
  }
}
