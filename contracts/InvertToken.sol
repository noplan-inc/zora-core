pragma solidity ^0.6.8;
pragma experimental ABIEncoderV2;

import {ERC721Burnable} from "./ERC721Burnable.sol";
import {ERC721} from "./ERC721.sol";
import {EnumerableSet} from  "@openzeppelin/contracts/utils/EnumerableSet.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Decimal} from "./Decimal.sol";
import {InvertAuction} from "./InvertAuction.sol";

contract InvertToken is ERC721Burnable {
    using Counters for Counters.Counter;
    using SafeMath for uint256;

    // Address for the auction
    address public _auctionContract;

    // Mapping from token to previous owner of the token
    mapping(uint256 => address) public previousTokenOwners;

    // Mapping from token id to creator address
    mapping(uint256 => address) public tokenCreators;

    // Mapping from creator address to their (enumerable) set of created tokens
    mapping(address => EnumerableSet.UintSet) private _creatorTokens;

    // Mapping from token id to sha256 hash of content
    mapping(uint256 => bytes32) public tokenContentHashes;

    //keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    bytes32 public DOMAIN_SEPARATOR;

    // Mapping from address to token id to permit nonce
    mapping (address => mapping (uint256 => uint256)) public permitNonces;

    Counters.Counter private _tokenIdTracker;

    event BidCreated(
        uint256 tokenId,
        address bidder
    );

    event AskCreated(
        uint256 tokenId,
        address owner,
        uint256 amount,
        address currency,
        uint256 currencyDecimals
    );

    // Event indicating uri was updated.
    event TokenURIUpdated(uint256 indexed _tokenId, address owner, string  _uri);

    modifier onlyExistingToken (uint256 tokenId) {
        require(_exists(tokenId), "InvertToken: Nonexistant token");
        _;
    }

    modifier onlyTokenWithContentHash (uint256 tokenId) {
        require(tokenContentHashes[tokenId] != "", "IntertToken: token does not have hash of created content");
        _;
    }

    modifier onlyApprovedOrOwner(address spender, uint256 tokenId) {
        require(_isApprovedOrOwner(spender, tokenId), "InvertToken: Only approved or owner");
        _;
    }

    modifier onlyAuction() {
        require(msg.sender == _auctionContract, "Invert: only auction contract");
        _;
    }

    modifier onlyOwner(uint256 tokenId) {
        require(_exists(tokenId), "ERC721: operator query for nonexistent token");
        address owner = ownerOf(tokenId);
        require(msg.sender == owner, "InvertToken: caller is not owner");
        _;
    }

    constructor(address auctionContract) public ERC721("Invert", "INVERT") {
        _auctionContract = auctionContract;
        DOMAIN_SEPARATOR = initDomainSeparator("Invert", "1");
    }

    /**
    * @dev Creates a new token for `creator`. Its token ID will be automatically
    * assigned (and available on the emitted {IERC721-Transfer} event), and the token
    * URI autogenerated based on the base URI passed at construction.
    *
    * See {ERC721-_safeMint}.
    */
    function mint(address creator, string memory tokenURI, bytes32 contentHash, InvertAuction.BidShares memory bidShares) public {
        // We cannot just use balanceOf to create the new tokenId because tokens
        // can be burned (destroyed), so we need a separate counter.
        uint256 tokenId = _tokenIdTracker.current();

        _safeMint(creator, tokenId);
        _tokenIdTracker.increment();
        _setContentHash(tokenId, contentHash);
        _setTokenURI(tokenId, tokenURI);
        _creatorTokens[creator].add(tokenId);

        tokenCreators[tokenId] = creator;
        previousTokenOwners[tokenId] = creator;
        InvertAuction(_auctionContract).addBidShares(tokenId, bidShares);
    }

    function auctionTransfer(uint256 tokenId, address bidder)
        public
        onlyAuction
    {
        previousTokenOwners[tokenId] = ownerOf(tokenId);
        _safeTransfer(ownerOf(tokenId), bidder, tokenId, '');
    }

    function setAsk(uint256 tokenId, InvertAuction.Ask memory ask) public
        onlyApprovedOrOwner(msg.sender, tokenId)
        onlyExistingToken(tokenId)
    {
        InvertAuction(_auctionContract).setAsk(tokenId, ask);
    }

    function setBid(uint256 tokenId, InvertAuction.Bid memory bid)
        onlyExistingToken(tokenId)
        public
    {
        InvertAuction(_auctionContract).setBid(tokenId, bid);
    }

    function removeBid(uint256 tokenId)
        public
    {
        InvertAuction(_auctionContract).removeBid(tokenId, msg.sender);
    }

    function acceptBid(uint256 tokenId, address bidder)
        onlyExistingToken(tokenId)
        onlyApprovedOrOwner(msg.sender, tokenId)
        public
    {
        InvertAuction(_auctionContract).acceptBid(tokenId, bidder);
    }

    function updateTokenURI(uint256 tokenId, string memory tokenURI)
        public
        onlyExistingToken(tokenId)
        onlyTokenWithContentHash(tokenId)
        onlyOwner(tokenId)
    {
        _setTokenURI(tokenId, tokenURI);
        emit TokenURIUpdated(tokenId, msg.sender, tokenURI);
    }

    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        onlyExistingToken(tokenId)
        external
    {
        require(deadline == 0 || deadline >= block.timestamp, "InvertToken: Permit expired");
        require(spender != address(0), "InvertToken: spender cannot be 0x0");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        spender,
                        tokenId,
                        permitNonces[ownerOf(tokenId)][tokenId]++,
                        deadline
                    )
                )
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);

        require(
            recoveredAddress != address(0)  && ownerOf(tokenId) == recoveredAddress,
            "InvertToken: Signature invalid"
        );

        _approve(spender, tokenId);
    }

    /**
     * @dev Initializes EIP712 DOMAIN_SEPARATOR based on the current contract and chain ID.
     */
    function initDomainSeparator(
        string memory name,
        string memory version
    )
    internal
    returns (bytes32)
    {
        uint256 chainID;
        /* solium-disable-next-line */
        assembly {
            chainID := chainid()
        }

        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainID,
                address(this)
            )
        );
    }

    function _setContentHash(uint256 tokenId, bytes32 contentHash)
        internal
        virtual
        onlyExistingToken(tokenId)
    {
        tokenContentHashes[tokenId] = contentHash;
    }
}