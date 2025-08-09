
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @title BaseNFTMarketplace
 * @dev Advanced NFT marketplace for Base blockchain with royalties, auctions, and collection management
 * @dev Supports ERC721 tokens, royalty payments, timed auctions, and cross-chain compatibility
 */
contract BaseNFTMarketplace is ReentrancyGuard, Ownable, Pausable {
    using Counters for Counters.Counter;

    struct Listing {
        uint256 listingId;
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 price;
        address paymentToken;
        bool active;
        uint256 createdAt;
        uint256 expiresAt;
    }

    struct Auction {
        uint256 auctionId;
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 startingPrice;
        uint256 currentBid;
        address currentBidder;
        address paymentToken;
        uint256 startTime;
        uint256 endTime;
        bool active;
        bool settled;
    }

    struct RoyaltyInfo {
        address recipient;
        uint256 percentage;
    }

    struct Collection {
        address contractAddress;
        string name;
        string description;
        address creator;
        uint256 floorPrice;
        uint256 totalVolume;
        bool verified;
        bool active;
    }

    Counters.Counter private _listingIds;
    Counters.Counter private _auctionIds;
    
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Auction) public auctions;
    mapping(address => RoyaltyInfo) public royalties;
    mapping(address => Collection) public collections;
    mapping(address => mapping(uint256 => uint256)) public tokenListings;
    mapping(address => mapping(uint256 => uint256)) public tokenAuctions;
    
    uint256 public marketplaceFee = 250;
    uint256 public constant MAX_ROYALTY = 1000;
    uint256 public constant FEE_DENOMINATOR = 10000;
    
    address[] public supportedTokens;
    mapping(address => bool) public isSupportedToken;

    event ListingCreated(uint256 indexed listingId, address indexed seller, address indexed nftContract, uint256 tokenId, uint256 price);
    event ListingSold(uint256 indexed listingId, address indexed buyer, uint256 price);
    event AuctionCreated(uint256 indexed auctionId, address indexed seller, address indexed nftContract, uint256 tokenId, uint256 startingPrice);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 finalPrice);

    constructor() {
        supportedTokens.push(address(0));
        isSupportedToken[address(0)] = true;
    }

    function createListing(address _nftContract, uint256 _tokenId, uint256 _price, address _paymentToken, uint256 _duration) external nonReentrant whenNotPaused {
        require(_price > 0, "Price must be greater than 0");
        require(isSupportedToken[_paymentToken], "Payment token not supported");
        require(collections[_nftContract].active, "Collection not active");
        require(IERC721(_nftContract).ownerOf(_tokenId) == msg.sender, "Not token owner");
        require(IERC721(_nftContract).isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        _listingIds.increment();
        uint256 listingId = _listingIds.current();

        listings[listingId] = Listing({
            listingId: listingId,
            seller: msg.sender,
            nftContract: _nftContract,
            tokenId: _tokenId,
            price: _price,
            paymentToken: _paymentToken,
            active: true,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + _duration
        });

        tokenListings[_nftContract][_tokenId] = listingId;
        emit ListingCreated(listingId, msg.sender, _nftContract, _tokenId, _price);
    }

    function buyListing(uint256 _listingId) external payable nonReentrant whenNotPaused {
        Listing storage listing = listings[_listingId];
        require(listing.active, "Listing not active");
        require(block.timestamp <= listing.expiresAt, "Listing expired");
        require(msg.sender != listing.seller, "Cannot buy own listing");

        uint256 totalPrice = listing.price;
        
        if (listing.paymentToken == address(0)) {
            require(msg.value >= totalPrice, "Insufficient ETH");
        } else {
            require(IERC20(listing.paymentToken).transferFrom(msg.sender, address(this), totalPrice), "Payment failed");
        }

        uint256 marketplaceFeeAmount = (totalPrice * marketplaceFee) / FEE_DENOMINATOR;
        uint256 royaltyAmount = 0;
        
        RoyaltyInfo memory royalty = royalties[listing.nftContract];
        if (royalty.recipient != address(0)) {
            royaltyAmount = (totalPrice * royalty.percentage) / FEE_DENOMINATOR;
        }

        uint256 sellerAmount = totalPrice - marketplaceFeeAmount - royaltyAmount;

        IERC721(listing.nftContract).transferFrom(listing.seller, msg.sender, listing.tokenId);

        if (listing.paymentToken == address(0)) {
            payable(listing.seller).transfer(sellerAmount);
            if (royaltyAmount > 0) {
                payable(royalty.recipient).transfer(royaltyAmount);
            }
        } else {
            IERC20(listing.paymentToken).transfer(listing.seller, sellerAmount);
            if (royaltyAmount > 0) {
                IERC20(listing.paymentToken).transfer(royalty.recipient, royaltyAmount);
            }
        }

        collections[listing.nftContract].totalVolume += totalPrice;
        listing.active = false;
        tokenListings[listing.nftContract][listing.tokenId] = 0;

        emit ListingSold(_listingId, msg.sender, totalPrice);
    }

    function createAuction(address _nftContract, uint256 _tokenId, uint256 _startingPrice, address _paymentToken, uint256 _duration) external nonReentrant whenNotPaused {
        require(_startingPrice > 0, "Starting price must be greater than 0");
        require(isSupportedToken[_paymentToken], "Payment token not supported");
        require(collections[_nftContract].active, "Collection not active");
        require(IERC721(_nftContract).ownerOf(_tokenId) == msg.sender, "Not token owner");
        require(IERC721(_nftContract).isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        _auctionIds.increment();
        uint256 auctionId = _auctionIds.current();

        auctions[auctionId] = Auction({
            auctionId: auctionId,
            seller: msg.sender,
            nftContract: _nftContract,
            tokenId: _tokenId,
            startingPrice: _startingPrice,
            currentBid: 0,
            currentBidder: address(0),
            paymentToken: _paymentToken,
            startTime: block.timestamp,
            endTime: block.timestamp + _duration,
            active: true,
            settled: false
        });

        tokenAuctions[_nftContract][_tokenId] = auctionId;
        emit AuctionCreated(auctionId, msg.sender, _nftContract, _tokenId, _startingPrice);
    }

    function placeBid(uint256 _auctionId, uint256 _bidAmount) external payable nonReentrant whenNotPaused {
        Auction storage auction = auctions[_auctionId];
        require(auction.active, "Auction not active");
        require(block.timestamp >= auction.startTime, "Auction not started");
        require(block.timestamp <= auction.endTime, "Auction ended");
        require(msg.sender != auction.seller, "Cannot bid on own auction");
        require(_bidAmount > auction.currentBid, "Bid too low");
        require(_bidAmount >= auction.startingPrice, "Bid below starting price");

        if (auction.paymentToken == address(0)) {
            require(msg.value >= _bidAmount, "Insufficient ETH");
        } else {
            require(IERC20(auction.paymentToken).transferFrom(msg.sender, address(this), _bidAmount), "Payment failed");
        }

        if (auction.currentBidder != address(0)) {
            if (auction.paymentToken == address(0)) {
                payable(auction.currentBidder).transfer(auction.currentBid);
            } else {
                IERC20(auction.paymentToken).transfer(auction.currentBidder, auction.currentBid);
            }
        }

        auction.currentBid = _bidAmount;
        auction.currentBidder = msg.sender;

        emit BidPlaced(_auctionId, msg.sender, _bidAmount);
    }

    function settleAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];
        require(auction.active, "Auction not active");
        require(block.timestamp > auction.endTime, "Auction still ongoing");
        require(!auction.settled, "Auction already settled");

        auction.active = false;
        auction.settled = true;
        tokenAuctions[auction.nftContract][auction.tokenId] = 0;

        if (auction.currentBidder != address(0)) {
            uint256 totalPrice = auction.currentBid;
            uint256 marketplaceFeeAmount = (totalPrice * marketplaceFee) / FEE_DENOMINATOR;
            uint256 royaltyAmount = 0;
            
            RoyaltyInfo memory royalty = royalties[auction.nftContract];
            if (royalty.recipient != address(0)) {
                royaltyAmount = (totalPrice * royalty.percentage) / FEE_DENOMINATOR;
            }

            uint256 sellerAmount = totalPrice - marketplaceFeeAmount - royaltyAmount;

            IERC721(auction.nftContract).transferFrom(auction.seller, auction.currentBidder, auction.tokenId);

            if (auction.paymentToken == address(0)) {
                payable(auction.seller).transfer(sellerAmount);
                if (royaltyAmount > 0) {
                    payable(royalty.recipient).transfer(royaltyAmount);
                }
            } else {
                IERC20(auction.paymentToken).transfer(auction.seller, sellerAmount);
                if (royaltyAmount > 0) {
                    IERC20(auction.paymentToken).transfer(royalty.recipient, royaltyAmount);
                }
            }

            collections[auction.nftContract].totalVolume += totalPrice;
            emit AuctionSettled(_auctionId, auction.currentBidder, totalPrice);
        } else {
            emit AuctionSettled(_auctionId, address(0), 0);
        }
    }

    function addCollection(address _contractAddress, string memory _name, string memory _description) external onlyOwner {
        require(_contractAddress != address(0), "Invalid contract address");
        require(!collections[_contractAddress].active, "Collection already exists");

        collections[_contractAddress] = Collection({
            contractAddress: _contractAddress,
            name: _name,
            description: _description,
            creator: msg.sender,
            floorPrice: 0,
            totalVolume: 0,
            verified: true,
            active: true
        });
    }

    function setRoyalty(address _nftContract, address _recipient, uint256 _percentage) external {
        require(collections[_nftContract].creator == msg.sender || msg.sender == owner(), "Not authorized");
        require(_percentage <= MAX_ROYALTY, "Royalty too high");

        royalties[_nftContract] = RoyaltyInfo({
            recipient: _recipient,
            percentage: _percentage
        });
    }

    function addSupportedToken(address _token) external onlyOwner {
        require(!isSupportedToken[_token], "Token already supported");
        supportedTokens.push(_token);
        isSupportedToken[_token] = true;
    }

    function cancelListing(uint256 _listingId) external nonReentrant {
        Listing storage listing = listings[_listingId];
        require(listing.active, "Listing not active");
        require(listing.seller == msg.sender, "Not listing owner");

        listing.active = false;
        tokenListings[listing.nftContract][listing.tokenId] = 0;
    }

    function updateMarketplaceFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee too high");
        marketplaceFee = _newFee;
    }

    function withdrawFees(address _token) external onlyOwner {
        if (_token == address(0)) {
            payable(owner()).transfer(address(this).balance);
        } else {
            IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
        }
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function getTotalListings() external view returns (uint256) { return _listingIds.current(); }
    function getTotalAuctions() external view returns (uint256) { return _auctionIds.current(); }
}
