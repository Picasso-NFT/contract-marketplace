// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./interfaces/INFTPriceTracker.sol";

contract PicassoNFTMarketplaceV1 is
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct ListingOrBid {
        /// @dev number of tokens for sale or requested (1 if ERC-721 token is active for sale) (for bids, quantity for ERC-721 can be greater than 1)
        uint64 quantity;
        /// @dev price per token sold, i.e. extended sale price equals this times quantity purchased. For bids, price offered per item.
        uint128 pricePerItem;
        /// @dev timestamp after which the listing/bid is invalid
        uint64 expirationTime;
        /// @dev the payment token for this listing/bid.
        address paymentTokenAddress;
    }

    struct CollectionOwnerFee {
        /// @dev the fee, out of 10,000, that this collection owner will be given for each sale
        uint32 fee;
        /// @dev the recipient of the collection specific fee
        address recipient;
    }

    enum TokenApprovalStatus {
        NOT_APPROVED,
        ERC_721_APPROVED,
        ERC_1155_APPROVED
    }

    /// @notice MARKETPLACE_ADMIN_ROLE role hash
    bytes32 public constant MARKETPLACE_ADMIN_ROLE =
        keccak256("MARKETPLACE_ADMIN_ROLE");

    /// @notice ERC165 interface signatures
    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC1155 = 0xd9b67a26;

    /// @notice the denominator for portion calculation, i.e. how many basis points are in 100%
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice the maximum fee which the owner may set (in units of basis points)
    uint256 public constant MAX_FEE = 1500;

    /// @notice the maximum fee which the collection owner may set
    uint256 public constant MAX_COLLECTION_FEE = 2000;

    /// @notice the minimum price for which any item can be sold
    uint256 public constant MIN_PRICE = 1e9;

    /// @notice the default token that is used for marketplace sales and fee payments. Can be overridden by collectionToTokenAddress.
    IERC20Upgradeable public paymentToken;

    /// @notice fee portion (in basis points) for each sale, (e.g. a value of 100 is 100/10000 = 1%). This is the fee if no collection owner fee is set.
    uint256 public fee;

    /// @notice address that receives fees
    address public feeReceipient;

    /// @notice mapping for listings, maps: nftAddress => tokenId => offeror
    mapping(address => mapping(uint256 => mapping(address => ListingOrBid)))
        public listings;

    /// @notice fee portion (in basis points) for each sale. This is used if a separate fee has been set for the collection owner.
    uint256 public feeWithCollectionOwner;

    /// @notice Maps the collection address to the fees which the collection owner collects. Some collections may not have a seperate fee, such as those owned by the Treasure DAO.
    mapping(address => CollectionOwnerFee)
        public collectionToCollectionOwnerFee;

    /// @notice Maps the collection address to the payment token that will be used for purchasing. If the address is the zero address, it will use the default paymentToken.
    mapping(address => address) public collectionToPaymentToken;

    /// @notice The address for weth.
    IERC20Upgradeable public weth;

    /// @notice mapping for token bids (721/1155): nftAddress => tokneId => offeror
    mapping(address => mapping(uint256 => mapping(address => ListingOrBid)))
        public tokenBids;

    /// @notice mapping for collection level bids (721 only): nftAddress => offeror
    mapping(address => mapping(address => ListingOrBid)) public collectionBids;

    /// @notice Indicates if bid related functions are active.
    bool public areBidsActive;

    /// @notice Address of the contract that tracks sales and prices of collections.
    address public priceTrackerAddress;

    /// @notice The fee portion was updated
    /// @param  fee new fee amount (in units of basis points)
    event UpdateFee(uint256 fee);

    /// @notice The fee portion was updated for collections that have a collection owner.
    /// @param  fee new fee amount (in units of basis points)
    event UpdateFeeWithCollectionOwner(uint256 fee);

    /// @notice A collection's fees have changed
    /// @param  _collection  The collection
    /// @param  _recipient   The recipient of the fees. If the address is 0, the collection fees for this collection have been removed.
    /// @param  _fee         The fee amount (in units of basis points)
    event UpdateCollectionOwnerFee(
        address _collection,
        address _recipient,
        uint256 _fee
    );

    /// @notice The fee recipient was updated
    /// @param  feeRecipient the new recipient to get fees
    event UpdateFeeRecipient(address feeRecipient);

    event TokenBidCreatedOrUpdated(
        address bidder,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        uint64 expirationTime,
        address paymentToken
    );

    event CollectionBidCreatedOrUpdated(
        address bidder,
        address nftAddress,
        uint64 quantity,
        uint128 pricePerItem,
        uint64 expirationTime,
        address paymentToken
    );

    event TokenBidCancelled(
        address bidder,
        address nftAddress,
        uint256 tokenId
    );

    event CollectionBidCancelled(address bidder, address nftAddress);

    event BidAccepted(
        address seller,
        address bidder,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        address paymentToken,
        BidType bidType
    );

    /// @notice An item was listed for sale
    /// @param  seller         the offeror of the item
    /// @param  nftAddress     which token contract holds the offered token
    /// @param  tokenId        the identifier for the offered token
    /// @param  quantity       how many of this token identifier are offered (or 1 for a ERC-721 token)
    /// @param  pricePerItem   the price (in units of the paymentToken) for each token offered
    /// @param  expirationTime UNIX timestamp after when this listing expires
    /// @param  paymentToken   the token used to list this item
    event ItemListed(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        uint64 expirationTime,
        address paymentToken
    );

    /// @notice An item listing was updated
    /// @param  seller         the offeror of the item
    /// @param  nftAddress     which token contract holds the offered token
    /// @param  tokenId        the identifier for the offered token
    /// @param  quantity       how many of this token identifier are offered (or 1 for a ERC-721 token)
    /// @param  pricePerItem   the price (in units of the paymentToken) for each token offered
    /// @param  expirationTime UNIX timestamp after when this listing expires
    /// @param  paymentToken   the token used to list this item
    event ItemUpdated(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        uint64 expirationTime,
        address paymentToken
    );

    /// @notice An item is no longer listed for sale
    /// @param  seller     former offeror of the item
    /// @param  nftAddress which token contract holds the formerly offered token
    /// @param  tokenId    the identifier for the formerly offered token
    event ItemCanceled(
        address indexed seller,
        address indexed nftAddress,
        uint256 indexed tokenId
    );

    /// @notice A listed item was sold
    /// @param  seller       the offeror of the item
    /// @param  buyer        the buyer of the item
    /// @param  nftAddress   which token contract holds the sold token
    /// @param  tokenId      the identifier for the sold token
    /// @param  quantity     how many of this token identifier where sold (or 1 for a ERC-721 token)
    /// @param  pricePerItem the price (in units of the paymentToken) for each token sold
    /// @param  paymentToken the payment token that was used to pay for this item
    event ItemSold(
        address seller,
        address buyer,
        address nftAddress,
        uint256 tokenId,
        uint64 quantity,
        uint128 pricePerItem,
        address paymentToken
    );

    /// @notice The sales tracker contract was update
    /// @param  _priceTrackerAddress the new address to call for sales price tracking
    event UpdateSalesTracker(address _priceTrackerAddress);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @notice Perform initial contract setup
    /// @dev    The initializer modifier ensures this is only called once, the owner should confirm this was properly
    ///         performed before publishing this contract address.
    /// @param  _initialFee          fee to be paid on each sale, in basis points
    /// @param  _initialFeeRecipient wallet to collets fees
    /// @param  _initialPaymentToken address of the token that is used for settlement
    function initialize(
        uint256 _initialFee,
        address _initialFeeRecipient,
        IERC20Upgradeable _initialPaymentToken
    ) external initializer {
        require(
            address(_initialPaymentToken) != address(0),
            "Cannot set address(0)"
        );

        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();

        _setRoleAdmin(MARKETPLACE_ADMIN_ROLE, MARKETPLACE_ADMIN_ROLE);
        _grantRole(MARKETPLACE_ADMIN_ROLE, msg.sender);

        setFee(_initialFee, _initialFee);
        setFeeRecipient(_initialFeeRecipient);
        paymentToken = _initialPaymentToken;
        areBidsActive = true;
    }

    function createOrUpdateListing(
        ListParams[] calldata _listParams
    ) external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < _listParams.length; i++) {
            ListParams calldata _listParam = _listParams[i];
            bool _existingListing = listings[_listParam._nftAddress][
                _listParam._tokenId
            ][_msgSender()].quantity > 0;
            _createListingWithoutEvent(
                _listParam._nftAddress,
                _listParam._tokenId,
                _listParam._quantity,
                _listParam._pricePerItem,
                _listParam._expirationTime,
                _listParam._paymentToken
            );
            // Keep the events the same as they were before.
            if (_existingListing) {
                emit ItemUpdated(
                    _msgSender(),
                    _listParam._nftAddress,
                    _listParam._tokenId,
                    _listParam._quantity,
                    _listParam._pricePerItem,
                    _listParam._expirationTime,
                    _listParam._paymentToken
                );
            } else {
                emit ItemListed(
                    _msgSender(),
                    _listParam._nftAddress,
                    _listParam._tokenId,
                    _listParam._quantity,
                    _listParam._pricePerItem,
                    _listParam._expirationTime,
                    _listParam._paymentToken
                );
            }
        }
    }

    /// @notice Performs the listing and does not emit the event
    /// @param  _nftAddress     which token contract holds the offered token
    /// @param  _tokenId        the identifier for the offered token
    /// @param  _quantity       how many of this token identifier are offered (or 1 for a ERC-721 token)
    /// @param  _pricePerItem   the price (in units of the paymentToken) for each token offered
    /// @param  _expirationTime UNIX timestamp after when this listing expires
    function _createListingWithoutEvent(
        address _nftAddress,
        uint256 _tokenId,
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken
    ) internal {
        require(_expirationTime > block.timestamp, "Invalid expiration time");
        require(_pricePerItem >= MIN_PRICE, "Below min price");
        IERC165Upgradeable nft165 = IERC165Upgradeable(_nftAddress);

        if (nft165.supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721Upgradeable nft = IERC721Upgradeable(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "Not owning item");
            require(
                nft.isApprovedForAll(_msgSender(), address(this)),
                "Item not approved"
            );
            require(_quantity == 1, "Cannot list multiple ERC721");
        } else if (nft165.supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155Upgradeable nft = IERC1155Upgradeable(_nftAddress);
            require(
                nft.balanceOf(_msgSender(), _tokenId) >= _quantity,
                "Must hold enough nfts"
            );
            require(
                nft.isApprovedForAll(_msgSender(), address(this)),
                "Item not approved"
            );
            require(_quantity > 0, "Nothing to list");
        } else {
            revert("Token is not approved for trading");
        }

        address _paymentTokenForCollection = getPaymentTokenForCollection(
            _nftAddress
        );
        require(
            _paymentTokenForCollection == _paymentToken,
            "Wrong payment token"
        );

        listings[_nftAddress][_tokenId][_msgSender()] = ListingOrBid(
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken
        );
    }

    function cancelListing(
        CancelListParams[] calldata _cancelListParams
    ) external nonReentrant {
        for (uint256 i = 0; i < _cancelListParams.length; i++) {
            CancelListParams calldata _cancelListParam = _cancelListParams[i];
            delete (
                listings[_cancelListParam.nftAddress][_cancelListParam.tokenId][
                    _msgSender()
                ]
            );
            emit ItemCanceled(
                _msgSender(),
                _cancelListParam.nftAddress,
                _cancelListParam.tokenId
            );
        }
    }

    function cancelBids(
        CancelBidParams[] calldata _cancelBidParams
    ) external nonReentrant {
        for (uint256 i = 0; i < _cancelBidParams.length; i++) {
            CancelBidParams calldata _cancelBidParam = _cancelBidParams[i];
            if (_cancelBidParam.bidType == BidType.COLLECTION) {
                collectionBids[_cancelBidParam.nftAddress][_msgSender()]
                    .quantity = 0;

                emit CollectionBidCancelled(
                    _msgSender(),
                    _cancelBidParam.nftAddress
                );
            } else {
                tokenBids[_cancelBidParam.nftAddress][_cancelBidParam.tokenId][
                    _msgSender()
                ].quantity = 0;

                emit TokenBidCancelled(
                    _msgSender(),
                    _cancelBidParam.nftAddress,
                    _cancelBidParam.tokenId
                );
            }
        }
    }

    /// @notice Creates a bid for a particular token.
    function createOrUpdateTokenBid(
        address _nftAddress,
        uint256 _tokenId,
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken
    ) external nonReentrant whenNotPaused whenBiddingActive {
        IERC165Upgradeable nft165 = IERC165Upgradeable(_nftAddress);

        if (nft165.supportsInterface(INTERFACE_ID_ERC721)) {
            require(_quantity == 1, "Token bid quantity 1 for ERC721");
        } else if (nft165.supportsInterface(INTERFACE_ID_ERC1155)) {
            require(_quantity > 0, "Bad quantity");
        } else {
            revert("Token is not approved for trading");
        }

        _createBidWithoutEvent(
            _nftAddress,
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken,
            tokenBids[_nftAddress][_tokenId][_msgSender()]
        );

        emit TokenBidCreatedOrUpdated(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken
        );
    }

    function createOrUpdateCollectionBid(
        address _nftAddress,
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken
    ) external nonReentrant whenNotPaused whenBiddingActive {
        IERC165Upgradeable nft165 = IERC165Upgradeable(_nftAddress);
        if (nft165.supportsInterface(INTERFACE_ID_ERC721)) {
            require(_quantity > 0, "Bad quantity");
        } else if (nft165.supportsInterface(INTERFACE_ID_ERC1155)) {
            revert("No collection bids on 1155s");
        } else {
            revert("Token is not approved for trading");
        }

        _createBidWithoutEvent(
            _nftAddress,
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken,
            collectionBids[_nftAddress][_msgSender()]
        );

        emit CollectionBidCreatedOrUpdated(
            _msgSender(),
            _nftAddress,
            _quantity,
            _pricePerItem,
            _expirationTime,
            _paymentToken
        );
    }

    function _createBidWithoutEvent(
        address _nftAddress,
        uint64 _quantity,
        uint128 _pricePerItem,
        uint64 _expirationTime,
        address _paymentToken,
        ListingOrBid storage _bid
    ) private {
        require(_expirationTime > block.timestamp, "Invalid expiration time");
        require(_pricePerItem >= MIN_PRICE, "Below min price");

        address _paymentTokenForCollection = getPaymentTokenForCollection(
            _nftAddress
        );
        require(
            _paymentTokenForCollection == _paymentToken,
            "Bad payment token"
        );

        IERC20Upgradeable _token = IERC20Upgradeable(_paymentToken);

        uint256 _totalAmountNeeded = _pricePerItem * _quantity;

        require(
            _token.allowance(_msgSender(), address(this)) >=
                _totalAmountNeeded &&
                _token.balanceOf(_msgSender()) >= _totalAmountNeeded,
            "Not enough tokens owned or allowed for bid"
        );

        _bid.quantity = _quantity;
        _bid.pricePerItem = _pricePerItem;
        _bid.expirationTime = _expirationTime;
        _bid.paymentTokenAddress = _paymentToken;
    }

    function acceptCollectionBid(
        AcceptBidParams[] calldata _acceptBidParams
    ) external nonReentrant whenNotPaused whenBiddingActive {
        for (uint256 i = 0; i < _acceptBidParams.length; i++) {
            AcceptBidParams calldata _acceptBidParam = _acceptBidParams[i];
            _acceptBid(_acceptBidParam, BidType.COLLECTION);
        }
    }

    function _acceptBid(
        AcceptBidParams calldata _acceptBidParams,
        BidType _bidType
    ) private {
        // Validate buy order
        require(
            _msgSender() != _acceptBidParams.bidder,
            "Cannot supply own bid"
        );
        require(_acceptBidParams.quantity > 0, "Nothing to supply to bidder");

        // Validate bid
        ListingOrBid storage _bid = _bidType == BidType.COLLECTION
            ? collectionBids[_acceptBidParams.nftAddress][
                _acceptBidParams.bidder
            ]
            : tokenBids[_acceptBidParams.nftAddress][_acceptBidParams.tokenId][
                _acceptBidParams.bidder
            ];

        require(_bid.quantity > 0, "Bid does not exist");
        require(_bid.expirationTime >= block.timestamp, "Bid expired");
        require(_bid.pricePerItem > 0, "Bid price invalid");
        require(
            _bid.quantity >= _acceptBidParams.quantity,
            "Not enough quantity"
        );
        require(
            _bid.pricePerItem == _acceptBidParams.pricePerItem,
            "Price does not match"
        );

        // Ensure the accepter, the bidder, and the collection all agree on the token to be used for the purchase.
        // If the token used for buying/selling has changed since the bid was created, this effectively blocks
        // all the old bids with the old payment tokens from being bought.
        address _paymentTokenForCollection = getPaymentTokenForCollection(
            _acceptBidParams.nftAddress
        );

        require(
            _bid.paymentTokenAddress == _acceptBidParams.paymentToken &&
                _acceptBidParams.paymentToken == _paymentTokenForCollection,
            "Wrong payment token"
        );

        // Transfer NFT to buyer, also validates owner owns it, and token is approved for trading
        IERC165Upgradeable nft165 = IERC165Upgradeable(
            _acceptBidParams.nftAddress
        );
        if (nft165.supportsInterface(INTERFACE_ID_ERC721)) {
            require(
                _acceptBidParams.quantity == 1,
                "Cannot supply multiple ERC721s"
            );

            IERC721Upgradeable(_acceptBidParams.nftAddress).safeTransferFrom(
                _msgSender(),
                _acceptBidParams.bidder,
                _acceptBidParams.tokenId
            );
        } else if (nft165.supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155Upgradeable(_acceptBidParams.nftAddress).safeTransferFrom(
                _msgSender(),
                _acceptBidParams.bidder,
                _acceptBidParams.tokenId,
                _acceptBidParams.quantity,
                bytes("")
            );
        } else {
            revert("Token is not approved for trading");
        }

        _payFees(
            _bid,
            _acceptBidParams.quantity,
            _acceptBidParams.nftAddress,
            _acceptBidParams.bidder,
            _msgSender(),
            _acceptBidParams.paymentToken,
            false
        );

        if (priceTrackerAddress != address(0)) {
            INFTPriceTracker(priceTrackerAddress).recordSale(
                _acceptBidParams.nftAddress,
                _acceptBidParams.tokenId,
                _bid.pricePerItem
            );
        }

        // Announce accepting bid
        emit BidAccepted(
            _msgSender(),
            _acceptBidParams.bidder,
            _acceptBidParams.nftAddress,
            _acceptBidParams.tokenId,
            _acceptBidParams.quantity,
            _acceptBidParams.pricePerItem,
            _acceptBidParams.paymentToken,
            _bidType
        );

        // Deplete or cancel listing
        _bid.quantity -= _acceptBidParams.quantity;
    }

    /// @notice Buy multiple listed items. You must authorize this marketplace with your payment token to completed the buy or purchase with eth if it is a weth collection.
    function buyItems(
        BuyItemParams[] calldata _buyItemParams
    ) external payable nonReentrant whenNotPaused {
        uint256 _ethAmountRequired;
        for (uint256 i = 0; i < _buyItemParams.length; i++) {
            _ethAmountRequired += _buyItem(_buyItemParams[i]);
        }

        require(msg.value == _ethAmountRequired, "Bad ETH value");
    }

    // Returns the amount of eth a user must have sent.
    function _buyItem(
        BuyItemParams calldata _buyItemParams
    ) private returns (uint256) {
        // Validate buy order
        require(
            _msgSender() != _buyItemParams.owner,
            "Cannot buy your own item"
        );
        require(_buyItemParams.quantity > 0, "Nothing to buy");

        // Validate listing
        ListingOrBid memory listedItem = listings[_buyItemParams.nftAddress][
            _buyItemParams.tokenId
        ][_buyItemParams.owner];
        require(listedItem.quantity > 0, "Not listed item");
        require(
            listedItem.expirationTime >= block.timestamp,
            "Listing expired"
        );
        require(listedItem.pricePerItem > 0, "Listing price invalid");
        require(
            listedItem.quantity >= _buyItemParams.quantity,
            "not enough quantity"
        );
        require(
            listedItem.pricePerItem <= _buyItemParams.maxPricePerItem,
            "Price increased"
        );

        // Ensure the buyer, the seller, and the collection all agree on the token to be used for the purchase.
        // If the token used for buying/selling has changed since the listing was created, this effectively blocks
        // all the old listings with the old payment tokens from being bought.
        address _paymentTokenForCollection = getPaymentTokenForCollection(
            _buyItemParams.nftAddress
        );
        address _paymentTokenForListing = _getPaymentTokenForListing(
            listedItem
        );

        require(
            _paymentTokenForListing == _buyItemParams.paymentToken &&
                _buyItemParams.paymentToken == _paymentTokenForCollection,
            "Wrong payment token"
        );

        if (_buyItemParams.usingEth) {
            require(
                _paymentTokenForListing == address(weth),
                "ETH only used with weth collection"
            );
        }

        // Transfer NFT to buyer, also validates owner owns it, and token is approved for trading
        IERC165Upgradeable nft165 = IERC165Upgradeable(
            _buyItemParams.nftAddress
        );
        if (nft165.supportsInterface(INTERFACE_ID_ERC721)) {
            require(_buyItemParams.quantity == 1, "Cannot buy multiple ERC721");
            IERC721Upgradeable(_buyItemParams.nftAddress).safeTransferFrom(
                _buyItemParams.owner,
                _msgSender(),
                _buyItemParams.tokenId
            );
        } else if (nft165.supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155Upgradeable(_buyItemParams.nftAddress).safeTransferFrom(
                _buyItemParams.owner,
                _msgSender(),
                _buyItemParams.tokenId,
                _buyItemParams.quantity,
                bytes("")
            );
        } else {
            revert("token is not approved for trading");
        }

        _payFees(
            listedItem,
            _buyItemParams.quantity,
            _buyItemParams.nftAddress,
            _msgSender(),
            _buyItemParams.owner,
            _buyItemParams.paymentToken,
            _buyItemParams.usingEth
        );

        // Announce sale
        emit ItemSold(
            _buyItemParams.owner,
            _msgSender(),
            _buyItemParams.nftAddress,
            _buyItemParams.tokenId,
            _buyItemParams.quantity,
            listedItem.pricePerItem, // this is deleted below in "Deplete or cancel listing"
            _buyItemParams.paymentToken
        );

        // Deplete or cancel listing
        if (listedItem.quantity == _buyItemParams.quantity) {
            delete listings[_buyItemParams.nftAddress][_buyItemParams.tokenId][
                _buyItemParams.owner
            ];
        } else {
            listings[_buyItemParams.nftAddress][_buyItemParams.tokenId][
                _buyItemParams.owner
            ].quantity -= _buyItemParams.quantity;
        }

        if (priceTrackerAddress != address(0)) {
            INFTPriceTracker(priceTrackerAddress).recordSale(
                _buyItemParams.nftAddress,
                _buyItemParams.tokenId,
                listedItem.pricePerItem
            );
        }

        if (_buyItemParams.usingEth) {
            return _buyItemParams.quantity * listedItem.pricePerItem;
        } else {
            return 0;
        }
    }

    /// @dev pays the fees to the marketplace fee recipient, the collection recipient if one exists, and to the seller of the item.
    /// @param _listOrBid the item that is being purchased/accepted
    /// @param _quantity the quantity of the item being purchased/accepted
    /// @param _collectionAddress the collection to which this item belongs
    function _payFees(
        ListingOrBid memory _listOrBid,
        uint256 _quantity,
        address _collectionAddress,
        address _from,
        address _to,
        address _paymentTokenAddress,
        bool _usingEth
    ) private {
        IERC20Upgradeable _paymentToken = IERC20Upgradeable(
            _paymentTokenAddress
        );

        // Handle purchase price payment
        uint256 _totalPrice = _listOrBid.pricePerItem * _quantity;

        address _collectionFeeRecipient = collectionToCollectionOwnerFee[
            _collectionAddress
        ].recipient;

        uint256 _protocolFee;
        uint256 _collectionFee;

        if (_collectionFeeRecipient != address(0)) {
            _protocolFee = feeWithCollectionOwner;
            _collectionFee = collectionToCollectionOwnerFee[_collectionAddress]
                .fee;
        } else {
            _protocolFee = fee;
            _collectionFee = 0;
        }

        uint256 _protocolFeeAmount = (_totalPrice * _protocolFee) /
            BASIS_POINTS;
        uint256 _collectionFeeAmount = (_totalPrice * _collectionFee) /
            BASIS_POINTS;

        _transferAmount(
            _from,
            feeReceipient,
            _protocolFeeAmount,
            _paymentToken,
            _usingEth
        );
        _transferAmount(
            _from,
            _collectionFeeRecipient,
            _collectionFeeAmount,
            _paymentToken,
            _usingEth
        );

        // Transfer rest to seller
        _transferAmount(
            _from,
            _to,
            _totalPrice - _protocolFeeAmount - _collectionFeeAmount,
            _paymentToken,
            _usingEth
        );
    }

    function _transferAmount(
        address _from,
        address _to,
        uint256 _amount,
        IERC20Upgradeable _paymentToken,
        bool _usingEth
    ) private {
        if (_amount == 0) {
            return;
        }

        if (_usingEth) {
            (bool _success, ) = payable(_to).call{value: _amount}("");
            require(_success, "Sending eth was not successful");
        } else {
            _paymentToken.safeTransferFrom(_from, _to, _amount);
        }
    }

    function getPaymentTokenForCollection(
        address _collection
    ) public view returns (address) {
        address _collectionPaymentToken = collectionToPaymentToken[_collection];

        // For backwards compatability. If a collection payment wasn't set at the collection level, it was using the payment token.
        return
            _collectionPaymentToken == address(0)
                ? address(paymentToken)
                : _collectionPaymentToken;
    }

    function _getPaymentTokenForListing(
        ListingOrBid memory listedItem
    ) private view returns (address) {
        // For backwards compatability. If a listing has no payment token address, it was using the original, default payment token.
        return
            listedItem.paymentTokenAddress == address(0)
                ? address(paymentToken)
                : listedItem.paymentTokenAddress;
    }

    // Owner administration ////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Updates the fee amount which is collected during sales, for both collections with and without owner specific fees.
    /// @dev    This is callable only by the owner. Both fees may not exceed MAX_FEE
    /// @param  _newFee the updated fee amount is basis points
    function setFee(
        uint256 _newFee,
        uint256 _newFeeWithCollectionOwner
    ) public onlyRole(MARKETPLACE_ADMIN_ROLE) {
        require(
            _newFee <= MAX_FEE && _newFeeWithCollectionOwner <= MAX_FEE,
            "Max fee"
        );

        fee = _newFee;
        feeWithCollectionOwner = _newFeeWithCollectionOwner;

        emit UpdateFee(_newFee);
        emit UpdateFeeWithCollectionOwner(_newFeeWithCollectionOwner);
    }

    /// @notice Updates the fee amount which is collected during sales fro a specific collection
    /// @dev    This is callable only by the owner
    /// @param  _collectionAddress The collection in question. This must be whitelisted.
    /// @param _collectionOwnerFee The fee and recipient for the collection. If the 0 address is passed as the recipient, collection specific fees will not be collected.
    function setCollectionOwnerFee(
        address _collectionAddress,
        CollectionOwnerFee calldata _collectionOwnerFee
    ) external {
        OwnableUpgradeable collection = OwnableUpgradeable(_collectionAddress);
        require(
            collection.owner() == _msgSender() ||
                hasRole(MARKETPLACE_ADMIN_ROLE, _msgSender()),
            "No permission"
        );
        require(
            _collectionOwnerFee.fee <= MAX_COLLECTION_FEE,
            "Collection fee too high"
        );

        // The collection recipient can be the 0 address, meaning we will treat this as a collection with no collection owner fee.
        collectionToCollectionOwnerFee[
            _collectionAddress
        ] = _collectionOwnerFee;

        emit UpdateCollectionOwnerFee(
            _collectionAddress,
            _collectionOwnerFee.recipient,
            _collectionOwnerFee.fee
        );
    }

    /// @notice Updates the fee recipient which receives fees during sales
    /// @dev    This is callable only by the owner.
    /// @param  _newFeeRecipient the wallet to receive fees
    function setFeeRecipient(
        address _newFeeRecipient
    ) public onlyRole(MARKETPLACE_ADMIN_ROLE) {
        require(_newFeeRecipient != address(0), "Cannot set 0x0 address");
        feeReceipient = _newFeeRecipient;
        emit UpdateFeeRecipient(_newFeeRecipient);
    }

    function setWeth(
        address _wethAddress
    ) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        require(address(weth) == address(0), "WETH address already set");

        weth = IERC20Upgradeable(_wethAddress);
    }

    /// @notice Updates the fee recipient which receives fees during sales
    /// @dev    This is callable only by the owner.
    /// @param  _priceTrackerAddress the wallet to receive fees
    function setPriceTracker(
        address _priceTrackerAddress
    ) public onlyRole(MARKETPLACE_ADMIN_ROLE) {
        require(_priceTrackerAddress != address(0), "Cannot set 0x0 address");
        priceTrackerAddress = _priceTrackerAddress;
        emit UpdateSalesTracker(_priceTrackerAddress);
    }

    function toggleAreBidsActive() external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        areBidsActive = !areBidsActive;
    }

    /// @notice Pauses the marketplace, creatisgn and executing listings is paused
    /// @dev    This is callable only by the owner. Canceling listings is not paused.
    function pause() external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the marketplace, all functionality is restored
    /// @dev    This is callable only by the owner.
    function unpause() external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        _unpause();
    }

    modifier whenBiddingActive() {
        require(areBidsActive, "Bidding is not active");

        _;
    }
}

struct ListParams {
    address _nftAddress;
    uint256 _tokenId;
    uint64 _quantity;
    // the price for each token
    uint128 _pricePerItem;
    uint64 _expirationTime;
    /// the payment token to be used
    address _paymentToken;
}

struct BuyItemParams {
    /// which token contract holds the offered token
    address nftAddress;
    /// the identifier for the token to be bought
    uint256 tokenId;
    /// current owner of the item(s) to be bought
    address owner;
    /// how many of this token identifier to be bought (or 1 for a ERC-721 token)
    uint64 quantity;
    /// the maximum price (in units of the paymentToken) for each token offered
    uint128 maxPricePerItem;
    /// the payment token to be used
    address paymentToken;
    /// indicates if the user is purchasing this item with eth.
    bool usingEth;
}

struct AcceptBidParams {
    // Which token contract holds the given tokens
    address nftAddress;
    // The token id being given
    uint256 tokenId;
    // The user who created the bid initially
    address bidder;
    // The quantity of items being supplied to the bidder
    uint64 quantity;
    // The price per item that the bidder is offering
    uint128 pricePerItem;
    /// the payment token to be used
    address paymentToken;
}

struct CancelListParams {
    address nftAddress;
    uint256 tokenId;
}

struct CancelBidParams {
    BidType bidType;
    address nftAddress;
    uint256 tokenId;
}

enum BidType {
    TOKEN,
    COLLECTION
}
