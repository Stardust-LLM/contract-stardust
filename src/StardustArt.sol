// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Chainlink price feed (AggregatorV3Interface subset).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title StardustArt — "Attacker × Defender" (ERC-721)
 * @notice Public mint at a flat $0.20 per token, paid in ETH at the live Chainlink ETH/USD price. The ETH goes straight
 *         to the treasury (the dev wallet) in the same transaction; the contract never holds it.
 *
 * Supply
 *   - MAX_SUPPLY 100,000, ever (public mints + event airdrops). After that nothing can be minted.
 *   - Release schedule from `startTime`: 50 open every week and an extra 100 every 30 days, the first of each at
 *     `startTime`. It is cumulative, so whatever is not minted carries over to the next period.
 *     `released()` = opened so far, `available()` = still mintable now, `nextReleaseAt()` = countdown target.
 *   - Event airdrops: closed by default. The owner opens a number (e.g. 10), then either lists the winners' wallets
 *     (`addAirdropWinners`), who each claim their free NFT themselves with `claimAirdrop()`, or sends them directly
 *     (`airdrop`). Opened and assigned-but-unclaimed airdrops are reserved inside the 100,000. `closeAirdrop()` gives
 *     the unassigned part back; `revokeAirdrop(winner)` takes back an unclaimed one.
 *
 * Traits
 *   Each token stores the L2 block it was minted in. Its traits come from the hash of the NEXT block, which nobody
 *   knows when sending the mint, so a minter cannot pick a good roll. Metadata: `tokenURI` = baseURI + id (fixed at
 *   deploy, https://stardust.xyz/api/art/), `contractURI` for marketplaces such as OpenSea.
 */
contract StardustArt is ERC721, Ownable2Step, ReentrancyGuard, Pausable {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 100_000;
    uint256 public constant WEEKLY_RELEASE = 50;
    uint256 public constant MONTHLY_RELEASE = 100;
    uint256 public constant WEEK = 7 days;
    uint256 public constant MONTH = 30 days;
    uint256 public constant PRICE_USD_CENTS = 20; // $0.20 per token
    uint256 public constant MAX_PER_TX = 10;
    uint256 public constant MIN_PRICE_AGE = 1 hours;
    uint256 public constant MAX_PRICE_AGE_LIMIT = 3 days;
    address private constant ARB_SYS = address(0x64); // Arbitrum-style chains: L2 block number

    uint64 public immutable startTime;
    string private _base; // fixed at deploy

    IPriceFeed public priceFeed;
    address payable public treasury;
    uint256 public maxPriceAge = 1 days; // oracle answer older than this = no mint (Chainlink heartbeat is 24 h)

    uint256 public totalMinted; // public + airdrop
    uint256 public publicMinted;
    uint256 public airdropMinted;
    uint256 public airdropOpen; // opened by the owner, not assigned yet (reserved)
    uint256 public airdropPending; // assigned to winners, not claimed yet (reserved)
    uint256 public totalPaid; // wei forwarded to the treasury

    mapping(uint256 => uint64) public mintBlock; // L2 block of each mint
    mapping(address => uint256) public airdropClaimable; // free NFTs a winner can claim

    event Minted(address indexed to, uint256 firstId, uint256 quantity, uint256 paidWei, uint256 ethUsdPrice);
    event AirdropOpened(uint256 added, uint256 open);
    event AirdropClosed(uint256 returned);
    event Airdropped(address indexed to, uint256 tokenId);
    event AirdropWinnersAdded(uint256 count, uint256 pending);
    event AirdropClaimed(address indexed to, uint256 firstId, uint256 quantity);
    event AirdropRevoked(address indexed winner, uint256 quantity);
    event TreasuryUpdated(address indexed treasury);
    event PriceFeedUpdated(address indexed feed);
    event MaxPriceAgeUpdated(uint256 maxAge);

    error ZeroAddress();
    error BadQuantity(uint256 quantity);
    error NotStarted(uint256 startTime);
    error NotReleased(uint256 available, uint256 quantity);
    error SoldOut(uint256 left, uint256 quantity);
    error Underpaid(uint256 cost, uint256 paid);
    error BadPrice();
    error StalePrice(uint256 updatedAt);
    error TransferFailed();
    error AirdropClosedOrTooSmall(uint256 open, uint256 quantity);
    error NothingToClaim();
    error BadMaxPriceAge();
    error RenounceDisabled();

    /// @param name_ / symbol_ the collection's on-chain name and ticker (marketplaces show them), fixed at deploy
    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address payable treasury_,
        IPriceFeed feed_,
        uint64 startTime_,
        string memory baseURI_
    ) ERC721(name_, symbol_) Ownable(owner_) {
        if (treasury_ == address(0) || address(feed_) == address(0)) revert ZeroAddress();
        treasury = treasury_;
        priceFeed = feed_;
        startTime = startTime_;
        _base = baseURI_;
        emit TreasuryUpdated(treasury_);
        emit PriceFeedUpdated(address(feed_));
    }

    // ================================================================== public mint

    /// @notice Mint `quantity` (1–10) for `quantity × $0.20` in ETH. Send at least `priceWei(quantity)`; the rest is
    ///         refunded in the same call (send a little extra in case the ETH price moves while the tx is pending).
    function mint(uint256 quantity) external payable nonReentrant whenNotPaused returns (uint256 firstId) {
        if (quantity == 0 || quantity > MAX_PER_TX) revert BadQuantity(quantity);
        if (block.timestamp < startTime) revert NotStarted(startTime);
        uint256 avail = available();
        if (quantity > avail) revert NotReleased(avail, quantity);
        uint256 left = MAX_SUPPLY - totalMinted - _reserved();
        if (quantity > left) revert SoldOut(left, quantity);

        (uint256 cost, uint256 ethUsd) = _price(quantity);
        if (msg.value < cost) revert Underpaid(cost, msg.value);

        firstId = totalMinted + 1;
        publicMinted += quantity;
        totalMinted += quantity;
        totalPaid += cost;
        uint64 blk = _l2Block();
        for (uint256 i; i < quantity; ++i) {
            mintBlock[firstId + i] = blk;
            _mint(msg.sender, firstId + i);
        }
        emit Minted(msg.sender, firstId, quantity, cost, ethUsd);

        _send(treasury, cost);
        if (msg.value > cost) _send(payable(msg.sender), msg.value - cost);
    }

    /// @notice ETH (wei) that `quantity` tokens cost right now at the oracle price.
    function priceWei(uint256 quantity) external view returns (uint256 cost) {
        (cost,) = _price(quantity);
    }

    // ================================================================== schedule

    /// @notice Public mints opened so far: 50 per started week + 100 per started 30 days (cumulative, so unminted ones carry over).
    function released() public view returns (uint256) {
        if (block.timestamp < startTime) return 0;
        uint256 elapsed = block.timestamp - startTime;
        uint256 r = (elapsed / WEEK + 1) * WEEKLY_RELEASE + (elapsed / MONTH + 1) * MONTHLY_RELEASE;
        return Math.min(r, MAX_SUPPLY);
    }

    /// @notice Public mints possible right now.
    function available() public view returns (uint256) {
        uint256 r = released();
        uint256 open = r > publicMinted ? r - publicMinted : 0;
        uint256 left = MAX_SUPPLY - totalMinted - _reserved();
        return Math.min(open, left);
    }

    /// @notice When the next batch opens (the earlier of the next week and the next 30-day release); 0 when sold out.
    function nextReleaseAt() external view returns (uint256 at, uint256 amount) {
        if (totalMinted + _reserved() >= MAX_SUPPLY) return (0, 0);
        if (block.timestamp < startTime) return (startTime, WEEKLY_RELEASE + MONTHLY_RELEASE);
        uint256 elapsed = block.timestamp - startTime;
        uint256 nextWeek = startTime + (elapsed / WEEK + 1) * WEEK;
        uint256 nextMonth = startTime + (elapsed / MONTH + 1) * MONTH;
        at = Math.min(nextWeek, nextMonth);
        amount = (at == nextWeek ? WEEKLY_RELEASE : 0) + (at == nextMonth ? MONTHLY_RELEASE : 0);
    }

    // ================================================================== event airdrop (owner)

    /// @notice Open `supply` more airdrop tokens (reserved inside MAX_SUPPLY until sent or closed).
    function openAirdrop(uint256 supply) external onlyOwner {
        if (supply == 0) revert BadQuantity(0);
        uint256 left = MAX_SUPPLY - totalMinted - _reserved();
        if (supply > left) revert SoldOut(left, supply);
        airdropOpen += supply;
        emit AirdropOpened(supply, airdropOpen);
    }

    /// @notice Close the airdrop; the unsent part goes back to the shared supply.
    function closeAirdrop() external onlyOwner {
        uint256 returned = airdropOpen;
        airdropOpen = 0;
        emit AirdropClosed(returned);
    }

    /// @notice Send one free token to each address (uses the opened airdrop supply).
    function airdrop(address[] calldata to) external onlyOwner nonReentrant {
        uint256 n = to.length;
        if (n == 0 || n > airdropOpen) revert AirdropClosedOrTooSmall(airdropOpen, n);
        airdropOpen -= n;
        airdropMinted += n;
        uint256 id = totalMinted;
        totalMinted += n;
        uint64 blk = _l2Block();
        for (uint256 i; i < n; ++i) {
            if (to[i] == address(0)) revert ZeroAddress();
            mintBlock[++id] = blk;
            _mint(to[i], id);
            emit Airdropped(to[i], id);
        }
    }

    /// @notice List winners: each address can claim one free NFT (listed twice = two). Uses the opened airdrop supply.
    function addAirdropWinners(address[] calldata winners) external onlyOwner {
        uint256 n = winners.length;
        if (n == 0 || n > airdropOpen) revert AirdropClosedOrTooSmall(airdropOpen, n);
        airdropOpen -= n;
        airdropPending += n;
        for (uint256 i; i < n; ++i) {
            if (winners[i] == address(0)) revert ZeroAddress();
            airdropClaimable[winners[i]] += 1;
        }
        emit AirdropWinnersAdded(n, airdropPending);
    }

    /// @notice Take back a winner's unclaimed NFTs (e.g. a wrong address); they go back to the open airdrop supply.
    function revokeAirdrop(address winner) external onlyOwner {
        uint256 n = airdropClaimable[winner];
        if (n == 0) revert NothingToClaim();
        airdropClaimable[winner] = 0;
        airdropPending -= n;
        airdropOpen += n;
        emit AirdropRevoked(winner, n);
    }

    /// @notice A listed winner claims their free NFT(s). Free (gas only); works even while the public mint is paused.
    function claimAirdrop() external nonReentrant returns (uint256 firstId) {
        uint256 n = airdropClaimable[msg.sender];
        if (n == 0) revert NothingToClaim();
        airdropClaimable[msg.sender] = 0;
        airdropPending -= n;
        airdropMinted += n;
        firstId = totalMinted + 1;
        totalMinted += n;
        uint64 blk = _l2Block();
        for (uint256 i; i < n; ++i) {
            mintBlock[firstId + i] = blk;
            _mint(msg.sender, firstId + i);
        }
        emit AirdropClaimed(msg.sender, firstId, n);
    }

    // ================================================================== owner

    function setTreasury(address payable treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Only to move to a new Chainlink ETH/USD proxy if the current one is retired.
    function setPriceFeed(IPriceFeed feed_) external onlyOwner {
        if (address(feed_) == address(0)) revert ZeroAddress();
        priceFeed = feed_;
        emit PriceFeedUpdated(address(feed_));
    }

    function setMaxPriceAge(uint256 maxAge) external onlyOwner {
        if (maxAge < MIN_PRICE_AGE || maxAge > MAX_PRICE_AGE_LIMIT) revert BadMaxPriceAge();
        maxPriceAge = maxAge;
        emit MaxPriceAgeUpdated(maxAge);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ================================================================== metadata

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(_base, tokenId.toString());
    }

    /// @notice Collection metadata for marketplaces (OpenSea reads this).
    function contractURI() external view returns (string memory) {
        return string.concat(_base, "collection");
    }

    function baseURI() external view returns (string memory) {
        return _base;
    }

    // ================================================================== internals

    /// @dev airdrops opened or assigned but not minted yet: kept out of the public mint
    function _reserved() internal view returns (uint256) {
        return airdropOpen + airdropPending;
    }

    function _price(uint256 quantity) internal view returns (uint256 cost, uint256 ethUsd) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert BadPrice();
        if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice(updatedAt);
        ethUsd = uint256(answer);
        // quantity x $0.20 in wei, rounded up so the treasury never receives less than $0.20 per token
        cost = Math.mulDiv(
            quantity * PRICE_USD_CENTS * 1e18, 10 ** priceFeed.decimals(), 100 * ethUsd, Math.Rounding.Ceil
        );
    }

    function _l2Block() internal view returns (uint64) {
        (bool ok, bytes memory out) = ARB_SYS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        return ok && out.length == 32 ? uint64(abi.decode(out, (uint256))) : uint64(block.number);
    }

    function _send(address payable to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
