// SPDX-License-Identifier: GPL-3.0
// ChatGPT 사용

pragma solidity ^0.8.0;

/**
 * @title IndianPoker
 * @notice Simple two-player Indian Poker smart contract implementation
 * @dev Randomness is insecure (chain‐based hashing) and some rules are approximated (speculation).
 */
contract IndianPoker_2 {
    // Game states
    enum State { WaitingForPlayers, Dealing, Betting, Showdown, Finished }
    State public state;

    // Player data structure
    struct Player {
        address addr;        // Player address
        uint256 chips;       // Number of chips the player currently holds
        uint8 card;          // The player's card value (2–14 for 2–A, 15 for Joker)
        uint256 contributed; // Total chips contributed to the current pot
        bool folded;         // Has the player folded?
        bool isAllIn;        // Has the player gone all-in?
    }

    // Mapping from address to Player struct, and fixed-size array of two addresses
    mapping(address => Player) public players;
    address[2] public playerAddrs;
    uint8 private playerCount;

    // Pot, current highest bet, and index of the player whose turn it is (0 or 1)
    uint256 public pot;
    uint256 public currentBet;
    uint8 public currentPlayer;

    // Events
    event GameJoined(address indexed player);
    event GameStarted(uint8 card0, uint8 card1);
    event BetPlaced(address indexed player, uint256 amount);
    event Called(address indexed player, uint256 amount);
    event Raised(address indexed player, uint256 newBet);
    event Folded(address indexed player);
    event AllIn(address indexed player, uint256 allInAmount);
    event ShowdownResult(address winner, uint8 winnerCard, uint8 loserCard);
    event ChipsPurchased(address indexed player, uint256 amountEth, uint256 chips);
    event ChipsExchanged(address indexed player, uint256 chips, uint256 amountEth);

    // Constants for chip/ETH conversions
    uint256 private constant INITIAL_JOIN_ETH = 0.001 ether;    // 0.001 ETH to join
    uint256 private constant CHIPS_PER_JOIN = 20;               // 20 chips granted on initial join
    uint256 private constant CHIPS_PER_0_001_ETH = 20;          // 20 chips per 0.001 ETH when buying
    uint256 private constant WEI_PER_0_001_ETH = 1e15;          // 0.001 ETH = 10^15 wei
    uint256 private constant WEI_PER_CHIP = 5e13;               // 0.00005 ETH (5×10^13 wei) per chip

    constructor() {
        state = State.WaitingForPlayers;
    }

    /**
     * @notice Buy chips with ETH (20 chips per 0.001 ETH)
     * @dev Calculates `msg.value * CHIPS_PER_0_001_ETH / WEI_PER_0_001_ETH`
     */
    function getChip() external payable {
        require(msg.value >= WEI_PER_0_001_ETH, "At least 0.001 ETH required.");
        uint256 chipsToCredit = (msg.value * CHIPS_PER_0_001_ETH) / WEI_PER_0_001_ETH;
        players[msg.sender].chips += chipsToCredit;
        emit ChipsPurchased(msg.sender, msg.value, chipsToCredit);
    }

    /**
     * @notice Exchange chips back to ETH (0.00005 ETH per chip)
     * @param chipAmount Number of chips to exchange
     */
    function exchange(uint256 chipAmount) external {
        Player storage p = players[msg.sender];
        require(p.chips >= chipAmount, "Insufficient chips for exchange.");
        p.chips -= chipAmount;
        uint256 ethToReturn = chipAmount * WEI_PER_CHIP;
        payable(msg.sender).transfer(ethToReturn);
        emit ChipsExchanged(msg.sender, chipAmount, ethToReturn);
    }

    /**
     * @notice Join the game by sending exactly 0.001 ETH. Automatically grants 20 chips.
     */
    function joinGame() external payable {
        require(state == State.WaitingForPlayers, "Not in waiting state.");
        require(playerCount < 2, "Already two players joined.");
        require(msg.value == INITIAL_JOIN_ETH, "Must send exactly 0.001 ETH to join.");
        require(players[msg.sender].addr == address(0), "Player already joined.");

        // Initialize new player
        players[msg.sender] = Player({
            addr: msg.sender,
            chips: CHIPS_PER_JOIN,
            card: 0,
            contributed: 0,
            folded: false,
            isAllIn: false
        });
        playerAddrs[playerCount] = msg.sender;
        playerCount++;
        emit GameJoined(msg.sender);

        // Start game once two players have joined
        if (playerCount == 2) {
            startGame();
        }
    }

    /**
     * @dev Internal: When two players are present, deal cards and move to betting phase.
     */
    function startGame() private {
        state = State.Dealing;
        dealCards();
        state = State.Betting;
        currentBet = 0;
        pot = 0;
        currentPlayer = 0;
        emit GameStarted(players[playerAddrs[0]].card, players[playerAddrs[1]].card);
    }

    /**
     * @dev Internal: Assign random cards (values 2–14 for 2 through Ace, 15 for Joker).
     * @notice Uses block timestamp and difficulty for pseudo-randomness (not secure).
     */
    function dealCards() private {
        bytes32 seed = keccak256(abi.encodePacked(block.timestamp, block.prevrandao));

        // Player 0's card
        uint8 v0 = uint8(uint256(keccak256(abi.encodePacked(seed, playerAddrs[0]))) % 14);
        if (v0 == 0) {
            players[playerAddrs[0]].card = 15; // Joker
        } else {
            players[playerAddrs[0]].card = v0 + 1; // 1→2, …, 13→14 (Ace)
        }

        // Player 1's card
        uint8 v1 = uint8(uint256(keccak256(abi.encodePacked(seed, playerAddrs[1]))) % 14);
        if (v1 == 0) {
            players[playerAddrs[1]].card = 15;
        } else {
            players[playerAddrs[1]].card = v1 + 1;
        }
    }

    /**
     * @notice Initial betting on the first turn: player may bet any positive chip amount.
     * @param amount Number of chips to bet (>0)
     */
    function bet(uint256 amount) external {
        require(state == State.Betting, "Not in betting phase.");
        require(msg.sender == playerAddrs[currentPlayer], "Not your turn.");
        Player storage p = players[msg.sender];
        require(!p.folded, "You have already folded.");
        require(currentBet == 0, "First bet already placed.");
        require(amount > 0 && p.chips >= amount, "Insufficient chips or invalid amount.");

        // Process initial bet
        currentBet = amount;
        p.chips -= amount;
        p.contributed = amount;
        pot += amount;
        emit BetPlaced(msg.sender, amount);

        // Switch turn to the other player
        currentPlayer = 1 - currentPlayer;
    }

    /**
     * @notice Call or go all-in:
     *   - If player’s chips <= needed to call, they go all-in.
     *   - Otherwise, match the current bet.
     */
    function callOrAllIn() external {
        require(state == State.Betting, "Not in betting phase.");
        require(msg.sender == playerAddrs[currentPlayer], "Not your turn.");
        Player storage p = players[msg.sender];
        require(!p.folded, "You have already folded.");
        require(currentBet > 0, "No active bet to call.");

        uint256 toCall = currentBet > p.contributed ? (currentBet - p.contributed) : 0;

        if (p.chips <= toCall) {
            // All-in call
            uint256 allInAmount = p.chips;
            p.contributed += allInAmount;
            pot += allInAmount;
            p.chips = 0;
            p.isAllIn = true;
            emit AllIn(msg.sender, allInAmount);
            // Note: If contributed < currentBet, side‐pot logic applies in showdown
        } else {
            // Normal call
            p.chips -= toCall;
            p.contributed += toCall;
            pot += toCall;
            emit Called(msg.sender, toCall);
        }

        // Determine if showdown or continue
        Player storage opponent = players[playerAddrs[1 - currentPlayer]];
        uint256 oppContribution = opponent.contributed;
        uint256 myContribution  = p.contributed;
        if (oppContribution == myContribution || opponent.folded) {
            // Either opponent folded earlier, or both contributions match → showdown
            state = State.Showdown;
            showdown();
        } else {
            // Otherwise, switch turn
            currentPlayer = 1 - currentPlayer;
        }
    }

    /**
     * @notice Raise the current bet to a higher amount.
     * @param newBet New total bet that must exceed currentBet
     */
    function raiseBet(uint256 newBet) external {
        require(state == State.Betting, "Not in betting phase.");
        require(msg.sender == playerAddrs[currentPlayer], "Not your turn.");
        Player storage p = players[msg.sender];
        require(!p.folded, "You have already folded.");
        require(newBet > currentBet, "Raise must exceed current bet.");
        uint256 additional = newBet > p.contributed ? (newBet - p.contributed) : 0;
        require(p.chips >= additional, "Insufficient chips for raise.");

        // Process raise
        p.chips -= additional;
        p.contributed = newBet;
        pot += additional;
        currentBet = newBet;
        emit Raised(msg.sender, newBet);

        // Switch turn
        currentPlayer = 1 - currentPlayer;
    }

    /**
     * @notice Fold: player gives up their contribution. If they hold an Ace (card==14), apply penalty.
     *   - Ace penalty: pay half of remaining chips (round up if odd) and add to pot.
     */
    function fold() external {
        require(state == State.Betting, "Not in betting phase.");
        require(msg.sender == playerAddrs[currentPlayer], "Not your turn.");
        Player storage p = players[msg.sender];
        require(!p.folded, "You have already folded.");

        // Mark fold
        p.folded = true;
        emit Folded(msg.sender);

        // Ace penalty if folded holding an Ace (14)
        if (p.card == 14) {
            uint256 penalty;
            if (p.chips % 2 == 1) {
                penalty = (p.chips / 2) + 1;
            } else {
                penalty = p.chips / 2;
            }
            if (penalty > 0) {
                p.chips -= penalty;
                pot += penalty;
            }
        }

        // The other player automatically wins the entire pot + contributions
        address winnerAddr = playerAddrs[1 - currentPlayer];
        awardPot(winnerAddr);
        state = State.Finished;
    }

    /**
     * @dev Internal: Showdown logic
     *   - Reveal both cards.
     *   - If tied, deal a new random card for each (single extra draw).
     *   - Compare and determine winner.
     */
    function showdown() private {
        Player storage p0 = players[playerAddrs[0]];
        Player storage p1 = players[playerAddrs[1]];

        uint8 card0 = p0.card;
        uint8 card1 = p1.card;

        if (card0 == card1) {
            // Tie → extra draw (re‐assign random card). Not from a real deck.
            bytes32 seed = keccak256(abi.encodePacked(block.timestamp, block.number));
            uint8 new0 = uint8(uint256(keccak256(abi.encodePacked(seed, p0.addr))) % 14);
            uint8 new1 = uint8(uint256(keccak256(abi.encodePacked(seed, p1.addr))) % 14);
            if (new0 == 0) { new0 = 15; } else { new0 += 1; }
            if (new1 == 0) { new1 = 15; } else { new1 += 1; }
            card0 = new0;
            card1 = new1;
        }

        address winnerAddr;
        if (card0 > card1) {
            winnerAddr = p0.addr;
        } else {
            winnerAddr = p1.addr;
        }

        emit ShowdownResult(winnerAddr,
            (winnerAddr == p0.addr) ? card0 : card1,
            (winnerAddr == p0.addr) ? card1 : card0
        );

        awardSidePot(winnerAddr);
        state = State.Finished;
    }

    /**
     * @dev Internal: Side‐pot logic for all‐in situations:
     *   - The smaller contributed amount between two players is doubled and awarded to the winner.
     *   - Any excess contribution is refunded to its owner.
     */
    function awardSidePot(address winnerAddr) private {
        Player storage p0 = players[playerAddrs[0]];
        Player storage p1 = players[playerAddrs[1]];

        uint256 c0 = p0.contributed;
        uint256 c1 = p1.contributed;
        uint256 minContrib = c0 < c1 ? c0 : c1;
        uint256 winnerChips = minContrib * 2;

        // Award winner
        players[winnerAddr].chips += winnerChips;

        // Refund any excess contributed
        if (c0 > minContrib) {
            uint256 refund0 = c0 - minContrib;
            p0.chips += refund0;
        }
        if (c1 > minContrib) {
            uint256 refund1 = c1 - minContrib;
            p1.chips += refund1;
        }
    }

    /**
     * @dev Internal: If someone folds, the other player gets all pot + both contributions.
     */
    function awardPot(address winnerAddr) private {
        Player storage p0 = players[playerAddrs[0]];
        Player storage p1 = players[playerAddrs[1]];

        uint256 totalAward = pot + p0.contributed + p1.contributed;
        players[winnerAddr].chips += totalAward;
    }

    /**
     * @notice Reset the game to initial state (clear both players). Only callable when state == Finished.
     */
    function resetGame() external {
        require(state == State.Finished, "Game must be finished to reset.");

        // Clear both players
        for (uint8 i = 0; i < 2; i++) {
            address addr = playerAddrs[i];
            delete players[addr];
            playerAddrs[i] = address(0);
        }
        playerCount = 0;
        pot = 0;
        currentBet = 0;
        state = State.WaitingForPlayers;
    }

    /**
     * @notice Get a player’s info (for debugging)
     * @param addr Address of the player to query
     * @return chips
     * @return card 
     * @return contributed 
     * @return folded
     * @return isAllIn
     */
    function getPlayerInfo(address addr) external view returns (
        uint256 chips,
        uint8 card,
        uint256 contributed,
        bool folded,
        bool isAllIn
    ) {
        Player storage p = players[addr];
        return (p.chips, p.card, p.contributed, p.folded, p.isAllIn);
    }
}
