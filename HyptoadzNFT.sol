// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title HyptoadzNFT
 * @notice ERC-721 NFT for the Hyptoadz collection on HyperEVM
 * @dev 10,000 supply — 3,538 airdrop + 6,462 public mint
 *
 * INSTANT REVEAL — metadata visible immediately upon mint
 * baseURI MUST be set before startMint() is called
 *
 * Token ID structure:
 *   Airdrop : #1     → #3,538
 *   Public  : #3,601 → #10,000
 */
contract HyptoadzNFT is ERC721, ERC721Enumerable, ERC2981, Ownable {

    // ── Constants ──────────────────────────────────────────────
    uint256 public constant MAX_SUPPLY     = 10_000;
    uint256 public constant AIRDROP_SUPPLY = 3_600;
    uint256 public constant PUBLIC_SUPPLY  = 6_400;

    // ── State ──────────────────────────────────────────────────
    address public mintContract;
    bool public transfersEnabled; // false until mint window ends
    string  private _baseTokenURI;
    bool    public  baseURILocked; // prevent changing URI after mint starts
    mapping(address => bool) public airdropReceived; // true if wallet has received airdrop
    uint256 public airdropMinted; // total NFTs distributed via airdrop

    uint256 public totalAirdropped;
    uint256 public totalPublicMinted;
    uint256 public totalBurnedUnsold;

    // Rarity: 0=Common 1=Uncommon 2=Rare 3=Legendary 4=Genesis
    mapping(uint256 => uint8) public rarityOf;

    // ── Events ─────────────────────────────────────────────────
    event MintContractSet(address indexed mintContract);
    event BaseURISet(string uri);
    event BaseURILocked();
    event RaritySet(uint256 indexed tokenId, uint8 rarity);
    event UnsoldBurned(uint256 amount);
    event TransfersEnabled();

    // ── Errors ─────────────────────────────────────────────────
    error NotMintContract();
    error InvalidRarity();
    error AirdropSupplyExceeded();
    error PublicSupplyExceeded();
    error BaseURINotSet();
    error BaseURIAlreadyLocked();
    error ZeroAddress();

    // ── Modifier ───────────────────────────────────────────────
    modifier onlyMintContract() {
        if (msg.sender != mintContract) revert NotMintContract();
        _;
    }

    // ── Constructor ────────────────────────────────────────────
    constructor(address _owner)
        ERC721("Hyptoadz", "HTOADZ")
        Ownable(_owner)
    {
        _setDefaultRoyalty(_owner, 250); // 2.5% royalty
    }

    // ── Admin ──────────────────────────────────────────────────

    error MintContractAlreadySet();

    function enableTransfers() external {
        require(msg.sender == mintContract, "Only mint contract");
        require(!transfersEnabled, "Already enabled");
        transfersEnabled = true;
        emit TransfersEnabled();
    }

    function setMintContract(address _mintContract) external onlyOwner {
        if (_mintContract == address(0)) revert ZeroAddress();
        if (mintContract != address(0)) revert MintContractAlreadySet();
        mintContract = _mintContract;
        emit MintContractSet(_mintContract);
    }

    /**
     * @notice Set IPFS base URI for metadata
     * @dev MUST be called before startMint() — instant reveal requires this
     *      Format: "ipfs://QmYourCID/"  (trailing slash required)
     *      Example: token #3539 → ipfs://QmYourCID/3539.json
     */
    function setBaseURI(string calldata uri) external onlyOwner {
        if (baseURILocked) revert BaseURIAlreadyLocked();
        _baseTokenURI = uri;
        emit BaseURISet(uri);
    }

    /**
     * @notice Lock base URI permanently — cannot be changed after
     * @dev Call this after confirming IPFS upload is correct
     *      Gives collectors confidence metadata cannot be changed
     */
    function lockBaseURI() external onlyOwner {
        if (baseURILocked) revert BaseURIAlreadyLocked();
        if (bytes(_baseTokenURI).length == 0) revert BaseURINotSet();
        baseURILocked = true;
        emit BaseURILocked();
    }

    /**
     * @notice Set rarity per token — call after all mints done
     * @dev Can be called in batches — ~500 per tx recommended
     */
    function setRarityBatch(
        uint256[] calldata tokenIds,
        uint8[]   calldata rarities
    ) external onlyOwner {
        require(!transfersEnabled, "Rarity locked after mint ends");
        if (tokenIds.length != rarities.length) revert InvalidRarity();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (rarities[i] > 4) revert InvalidRarity();
            rarityOf[tokenIds[i]] = rarities[i];
            emit RaritySet(tokenIds[i], rarities[i]);
        }
    }

    // ── Mint (called by HyptoadzMint only) ─────────────────────

    function mintPublic(address to, uint256 tokenId)
        external
        onlyMintContract
    {
        if (totalPublicMinted >= PUBLIC_SUPPLY) revert PublicSupplyExceeded();
        totalPublicMinted++;
        _safeMint(to, tokenId);
    }

    function airdropBatch(
        address[] calldata recipients,
        uint256[] calldata nftCounts,
        uint256[] calldata toadzAmounts
    ) external onlyMintContract {
        require(recipients.length == nftCounts.length, "Length mismatch");
        require(recipients.length == toadzAmounts.length, "Length mismatch");

        for (uint256 i = 0; i < recipients.length; ) {
            uint256 count = nftCounts[i];
            if (totalAirdropped + count > AIRDROP_SUPPLY)
                revert AirdropSupplyExceeded();
            for (uint256 j = 0; j < count; ) {
                totalAirdropped++;
                airdropMinted++;
                _mint(recipients[i], totalAirdropped);
                unchecked { j++; }
            }
            airdropReceived[recipients[i]] = true;
            unchecked { i++; }
        }
    }

    function recordUnsoldBurn(uint256 amount) external onlyMintContract {
        totalBurnedUnsold += amount;
        emit UnsoldBurned(amount);
    }

    // ── Views ──────────────────────────────────────────────────

    function effectiveSupply() external view returns (uint256) {
        return totalAirdropped + totalPublicMinted;
    }

    function rarityName(uint256 tokenId) external view returns (string memory) {
        uint8 r = rarityOf[tokenId];
        if (r == 0) return "Common";
        if (r == 1) return "Uncommon";
        if (r == 2) return "Rare";
        if (r == 3) return "Legendary";
        return "Genesis";
    }

    function isBaseURISet() external view returns (bool) {
        return bytes(_baseTokenURI).length > 0;
    }

    // ── Overrides ──────────────────────────────────────────────

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @notice INSTANT REVEAL — returns real metadata immediately
     * @dev No unrevealed state — baseURI must be set before mint
     *      tokenURI = baseURI + tokenId + ".json"
     *      Example: ipfs://QmXXX/3539.json
     */
    function tokenURI(uint256 tokenId)
        public view override returns (string memory)
    {
        _requireOwned(tokenId);
        return string(
            abi.encodePacked(_baseTokenURI, _toString(tokenId), ".json")
        );
    }

    // ── Internal ───────────────────────────────────────────────

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal override(ERC721, ERC721Enumerable)
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (!transfersEnabled) {
            require(
                from == address(0) || from == mintContract,
                "Transfers locked until mint ends"
            );
        }
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721, ERC721Enumerable, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
