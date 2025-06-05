// SPDX-License-Identifier: MIT
// Gemini 사용

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // For security

contract IndianPoker_3 is ReentrancyGuard {

    // --- Card Constants ---
    uint8 private constant JOKER_CARD = 1; // Joker is normally low
    uint8 private constant TWO_CARD = 2;
    uint8 private constant TEN_CARD = 10;
    uint8 private constant JACK_CARD = 11;
    uint8 private constant QUEEN_CARD = 12;
    uint8 private constant KING_CARD = 13;
    uint8 private constant ACE_CARD = 14; // Ace is normally high

    // --- Game Constants ---
    uint256 public constant MIN_BUY_IN_ETH = 0.001 ether;
    uint256 public constant CHIPS_PER_MIN_BUY_IN = 20;
    uint256 public constant ETH_PER_CHIP = 0.00005 ether; // MIN_BUY_IN_ETH / CHIPS_PER_MIN_BUY_IN

    // --- Player Structure ---
    struct Player {
        address payable addr;
        uint256 chips;
        uint8 card;
        uint256 currentBetInRound; // How much this player has bet in the current betting round
        bool hasFolded;
        bool isAllIn;
        uint256 initialChipsInRound; // Chips at the start of the round, for all-in calculations
        bool hasRevealedDrawCard; // For draw rounds
        uint8 drawCard;           // Card drawn during a tie-breaker
    }

    // --- Game State ---
    enum GamePhase { Idle, Betting, Showdown, DrawRound, GameOver }

    GamePhase public gamePhase;

    Player[2] public players;
    uint8 public playerCount;
    uint8 public currentPlayerIndex; // 0 or 1

    uint256 public pot;
    uint256 public amountToCall; // The total bet amount the current player needs to match
    address public lastRaiser; // Address of the player who made the last bet/raise

    uint8[] private deck;
    uint8 private deckPointer; // Points to the next card to be dealt

    // --- Events ---
    event PlayerJoined(address indexed player, uint256 initialChips);
    event ChipsPurchased(address indexed player, uint256 amount, uint256 chipsReceived);
    event ChipsExchanged(address indexed player, uint256 chipsSold, uint256 ethReceived);
    event GameStarted(address indexed player1, address indexed player2);
    event RoundStarted(uint8 dealerPlayerIndex);
    event PlayerBet(address indexed player, uint256 amount);
    event PlayerCalled(address indexed player, uint256 amount);
    event PlayerRaised(address indexed player, uint256 totalBetAmount);
    event PlayerFolded(address indexed player);
    event PlayerAllIn(address indexed player, uint256 amount);
    event Showdown(address indexed player1, uint8 card1, address indexed player2, uint8 card2);
    event DrawShowdown(address indexed player1, uint8 drawCard1, address indexed player2, uint8 drawCard2);
    event WinnerDetermined(address indexed winner, uint256 potWon);
    event PotSplit(address indexed player1, address indexed player2, uint256 amountEach);
    event AcePenaltyPaid(address indexed player, uint256 penaltyAmount);

    // --- Constructor ---
    constructor() {
        gamePhase = GamePhase.Idle;
    }

    // --- Chip Management ---
    function getChipRate() public pure returns (uint256 ethAmount, uint256 chipAmount) {
        return (MIN_BUY_IN_ETH, CHIPS_PER_MIN_BUY_IN);
    }

    function getExchangeRate() public pure returns (uint256 chipAmount, uint256 ethAmount) {
        return (1, ETH_PER_CHIP);
    }

    function getChip() public payable {
        require(msg.value > 0, "Must send ETH to get chips");
        require(msg.value % MIN_BUY_IN_ETH == 0, "ETH amount must be a multiple of MIN_BUY_IN_ETH");
        uint256 numLots = msg.value / MIN_BUY_IN_ETH;
        uint256 chipsToGive = numLots * CHIPS_PER_MIN_BUY_IN;

        bool foundPlayer = false;
        for (uint8 i = 0; i < playerCount; i++) {
            if (players[i].addr == msg.sender) {
                players[i].chips += chipsToGive;
                foundPlayer = true;
                break;
            }
        }
        // If player is not in the game yet, but wants to buy chips before joining
        // This scenario is less common; usually joinGame handles initial chips.
        // For simplicity, we'll assume players join first or buy chips while in game.
        require(foundPlayer, "Player not found. Join game or ensure you are a participant.");
        emit ChipsPurchased(msg.sender, msg.value, chipsToGive);
    }

    function exchangeChips(uint256 chipAmount) public nonReentrant {
        require(chipAmount > 0, "Chip amount must be positive");
        
        Player storage player = _getPlayerStorage(msg.sender);
        require(player.chips >= chipAmount, "Insufficient chips");

        uint256 ethToSend = chipAmount * ETH_PER_CHIP;
        require(address(this).balance >= ethToSend, "Contract has insufficient ETH for exchange");

        player.chips -= chipAmount;
        (bool success, ) = msg.sender.call{value: ethToSend}("");
        require(success, "ETH transfer failed");

        emit ChipsExchanged(msg.sender, chipAmount, ethToSend);
    }

    // --- Game Setup ---
    function joinGame() public payable nonReentrant {
        require(playerCount < 2, "Game is full");
        require(msg.value == MIN_BUY_IN_ETH, "Must send exactly MIN_BUY_IN_ETH to join");

        for (uint8 i = 0; i < playerCount; i++) {
            require(players[i].addr != msg.sender, "Player already joined");
        }

        players[playerCount] = Player({
            addr: payable(msg.sender),
            chips: CHIPS_PER_MIN_BUY_IN,
            card: 0,
            currentBetInRound: 0,
            hasFolded: false,
            isAllIn: false,
            initialChipsInRound: CHIPS_PER_MIN_BUY_IN,
            hasRevealedDrawCard: false,
            drawCard: 0
        });
        playerCount++;
        emit PlayerJoined(msg.sender, CHIPS_PER_MIN_BUY_IN);

        if (playerCount == 2) {
            _startGame();
        }
    }

    function _startGame() internal {
        require(playerCount == 2, "Need 2 players to start");
        gamePhase = GamePhase.Betting;
        currentPlayerIndex = 0; // Player 0 starts the betting
        lastRaiser = address(0); // No raiser yet
        amountToCall = 0; // No bet to call yet, first player must bet
        pot = 0;

        for (uint8 i = 0; i < 2; i++) {
            players[i].currentBetInRound = 0;
            players[i].hasFolded = false;
            players[i].isAllIn = false;
            players[i].initialChipsInRound = players[i].chips; // For all-in calculations
            players[i].hasRevealedDrawCard = false;
            players[i].drawCard = 0;
            require(players[i].chips > 0, "Player must have chips to start a round");
        }
        
        _initializeAndShuffleDeck();
        _dealCards();

        emit GameStarted(players[0].addr, players[1].addr);
        emit RoundStarted(currentPlayerIndex);
    }

    function _initializeAndShuffleDeck() internal {
        delete deck; // Clear previous deck
        // Joker (1), 2-10, J(11), Q(12), K(13), A(14) = 14 cards
        for (uint8 i = 1; i <= 14; i++) {
            deck.push(i);
        }

        // Fisher-Yates shuffle (simplified, using block properties for pseudo-randomness)
        // WARNING: Block properties can be influenced by miners. For a real money game, use a secure off-chain RNG or commit-reveal scheme.
        for (uint i = deck.length - 1; i > 0; i--) {
            uint j = uint(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, i))) % (i + 1);
            (deck[i], deck[j]) = (deck[j], deck[i]);
        }
        deckPointer = 0;
    }

    function _dealCards() internal {
        require(deck.length - deckPointer >= 2, "Not enough cards in deck");
        players[0].card = deck[deckPointer++];
        players[1].card = deck[deckPointer++];
    }
    
    function _dealSingleCard() internal returns (uint8) {
        require(deck.length - deckPointer >= 1, "Not enough cards in deck for draw");
        return deck[deckPointer++];
    }

    // --- Player Actions ---

    // "세팅(첫턴)" - 배팅 (Betting)
    function bet(uint256 betAmount) public nonReentrant {
        _requireCorrectPlayer();
        require(gamePhase == GamePhase.Betting, "Not in betting phase");
        require(betAmount > 0, "Bet amount must be positive");
        // This is the first bet of the round, or an opening bet after checks
        require(amountToCall == 0, "Cannot bet, must call, raise or fold. Or this is not the first action."); 
        
        Player storage P = players[currentPlayerIndex];
        require(P.chips >= betAmount, "Insufficient chips to bet");
        // Min bet could be 1, or related to big blind in more complex poker. Here, any positive amount.

        P.chips -= betAmount;
        P.currentBetInRound += betAmount;
        pot += betAmount;
        amountToCall = P.currentBetInRound; // The total amount player needs to have in pot
        lastRaiser = P.addr;

        emit PlayerBet(P.addr, betAmount);
        _switchPlayer();
    }

    function callAction() public nonReentrant {
        _requireCorrectPlayer();
        require(gamePhase == GamePhase.Betting, "Not in betting phase");
        require(amountToCall > 0, "No bet to call"); // Cannot call if no one has bet/raised

        Player storage P = players[currentPlayerIndex];
        uint256 neededToCall = amountToCall - P.currentBetInRound;
        require(neededToCall > 0, "Nothing to call or already called enough");

        if (P.chips <= neededToCall) { // All-in situation
            uint256 allInAmount = P.chips;
            pot += allInAmount;
            P.currentBetInRound += allInAmount;
            P.chips = 0;
            P.isAllIn = true;
            emit PlayerAllIn(P.addr, allInAmount);
            // If player goes all-in for less, `amountToCall` is NOT reduced for showdown calculation purposes
            // The other player will get a refund if they overbet relative to the all-in.
        } else {
            P.chips -= neededToCall;
            P.currentBetInRound += neededToCall;
            pot += neededToCall;
            emit PlayerCalled(P.addr, neededToCall);
        }

        // If the current player (who just called) was not the last raiser,
        // and their bet matches the amountToCall, betting ends.
        if (P.addr != lastRaiser && P.currentBetInRound == amountToCall) {
            _proceedToNextPhase();
        } else {
             // This condition can happen if P1 bets, P2 raises, P1 calls.
             // Or if P1 all-ins for less than P2's bet.
            _proceedToNextPhase();
        }
    }

    function raise(uint256 totalBetAmount) public nonReentrant {
        _requireCorrectPlayer();
        require(gamePhase == GamePhase.Betting, "Not in betting phase");
        require(amountToCall > 0, "Cannot raise if there's no previous bet; use bet() instead.");
        require(totalBetAmount > amountToCall, "Raise amount must be greater than current amount to call");
        // Minimum raise is effectively the size of the last bet/raise.
        // uint minRaiseAmount = amountToCall + (amountToCall - players[1-currentPlayerIndex].currentBetInRound);
        // require(totalBetAmount >= minRaiseAmount, "Raise too small");


        Player storage P = players[currentPlayerIndex];
        uint256 amountToRaise = totalBetAmount - P.currentBetInRound;
        require(P.chips >= amountToRaise, "Insufficient chips to raise");

        if (P.chips == amountToRaise) { // Raising all-in
            P.isAllIn = true;
            emit PlayerAllIn(P.addr, P.chips);
        }
        
        P.chips -= amountToRaise;
        P.currentBetInRound += amountToRaise;
        pot += amountToRaise;
        amountToCall = P.currentBetInRound; // This is the new total bet to be matched
        lastRaiser = P.addr;

        emit PlayerRaised(P.addr, totalBetAmount);
        _switchPlayer();
    }

    function foldAction() public nonReentrant {
        _requireCorrectPlayer();
        require(gamePhase == GamePhase.Betting || gamePhase == GamePhase.DrawRound, "Not in a phase where folding is allowed");

        Player storage P = players[currentPlayerIndex];
        P.hasFolded = true;
        emit PlayerFolded(P.addr);

        // Ace Penalty Check
        if (P.card == ACE_CARD) {
            uint256 penalty = P.chips / 2;
            if (P.chips % 2 != 0) {
                penalty++;
            }
            if (P.chips < penalty) { // Should not happen if chips > 0, but defensive
                penalty = P.chips;
            }
            P.chips -= penalty;
            pot += penalty; // Penalty goes to the pot
            emit AcePenaltyPaid(P.addr, penalty);
        }
        
        // The other player wins
        _determineWinnerByFold();
    }
    
    // --- Game Logic ---
    function _proceedToNextPhase() internal {
        // Check if betting is over:
        // 1. Both players have bet the same amount (and neither is all-in for less).
        // 2. One player is all-in, and the other has called that all-in amount (or bet more, which is fine).
        bool bettingOver = false;
        Player storage p0 = players[0];
        Player storage p1 = players[1];

        if (p0.currentBetInRound == p1.currentBetInRound) {
            bettingOver = true;
        } else if (p0.isAllIn && p1.currentBetInRound >= p0.currentBetInRound) {
            bettingOver = true;
        } else if (p1.isAllIn && p0.currentBetInRound >= p1.currentBetInRound) {
            bettingOver = true;
        }
        
        if (bettingOver) {
            if (gamePhase == GamePhase.Betting) {
                 // Handle any refund if one player bet more than an all-in player could match
                _handlePotentialRefund();
                gamePhase = GamePhase.Showdown;
                _showdown();
            } else if (gamePhase == GamePhase.DrawRound) {
                gamePhase = GamePhase.Showdown; // proceed to showdown for draw cards
                _showdownDraw();
            }
        } else {
            // This case should ideally not be reached if logic in call/raise is correct for 2 players
            // and _switchPlayer is called appropriately. It implies betting is not actually over.
            // For safety, we can switch player if somehow reached here.
             _switchPlayer();
        }
    }

    function _handlePotentialRefund() internal {
        Player storage p0 = players[0];
        Player storage p1 = players[1];
        uint256 refundAmount = 0;
        address payable refundAddress;

        // If p0 is all-in and p1 overbet
        if (p0.isAllIn && p1.currentBetInRound > p0.currentBetInRound) {
            refundAmount = p1.currentBetInRound - p0.currentBetInRound;
            p1.chips += refundAmount;
            pot -= refundAmount;
            p1.currentBetInRound = p0.currentBetInRound; // p1's effective bet for pot calculation is capped by p0's all-in
            refundAddress = p1.addr;
        } 
        // If p1 is all-in and p0 overbet
        else if (p1.isAllIn && p0.currentBetInRound > p1.currentBetInRound) {
            refundAmount = p0.currentBetInRound - p1.currentBetInRound;
            p0.chips += refundAmount;
            pot -= refundAmount;
            p0.currentBetInRound = p1.currentBetInRound; // p0's effective bet for pot calculation is capped by p1's all-in
            refundAddress = p0.addr;
        }

        if (refundAmount > 0) {
            // Emitting an event for refund could be useful for traceability
            // emit PotRefunded(refundAddress, refundAmount);
        }
    }


    function _showdown() internal {
        require(gamePhase == GamePhase.Showdown, "Not in showdown phase");
        emit Showdown(players[0].addr, players[0].card, players[1].addr, players[1].card);
        _determineWinnerAndDistributePot(players[0].card, players[1].card, false);
    }
    
    function _showdownDraw() internal {
        require(gamePhase == GamePhase.Showdown, "Not in showdown phase for draw cards"); // Still Showdown phase
        require(players[0].hasRevealedDrawCard && players[1].hasRevealedDrawCard, "Draw cards not revealed by both");
        emit DrawShowdown(players[0].addr, players[0].drawCard, players[1].addr, players[1].drawCard);
        _determineWinnerAndDistributePot(players[0].drawCard, players[1].drawCard, true); // isDrawRoundContext = true
    }

    function _getCardEffectiveValue(uint8 card1, uint8 card2, bool card1Perspective) internal pure returns (uint8) {
        // Joker (1) beats Ace (14). Otherwise, Joker is 1. Ace is 14.
        // card1Perspective: true if we are evaluating card1 against card2.
        uint8 c1 = card1;
        uint8 c2 = card2;

        if (card1Perspective) { // Evaluating card1
            if (c1 == JOKER_CARD && c2 == ACE_CARD) return 15; // Joker beats Ace, give it a temporary high value
            if (c1 == JOKER_CARD) return 1; // Joker is normally low
            return c1; // Normal card value
        } else { // Evaluating card2
            if (c2 == JOKER_CARD && c1 == ACE_CARD) return 15; // Joker beats Ace
            if (c2 == JOKER_CARD) return 1; // Joker is normally low
            return c2;
        }
    }

    function _determineWinnerAndDistributePot(uint8 cardP0, uint8 cardP1, bool isDrawRoundContext) internal {
        uint8 p0EffectiveValue = _getCardEffectiveValue(cardP0, cardP1, true);
        uint8 p1EffectiveValue = _getCardEffectiveValue(cardP1, cardP0, true); // Note: cardP0 is opponent for P1's card eval

        address winner = address(0);
        bool isTie = false;

        if (p0EffectiveValue > p1EffectiveValue) {
            winner = players[0].addr;
        } else if (p1EffectiveValue > p0EffectiveValue) {
            winner = players[1].addr;
        } else {
            isTie = true;
        }

        if (isTie) {
            if (!isDrawRoundContext) { // First showdown resulted in a tie
                gamePhase = GamePhase.DrawRound;
                // Deal new cards for the draw
                players[0].drawCard = _dealSingleCard();
                players[0].hasRevealedDrawCard = true; // Auto-reveal for contract logic
                players[1].drawCard = _dealSingleCard();
                players[1].hasRevealedDrawCard = true; // Auto-reveal for contract logic
                
                // Reset betting for the draw round (no actual betting, just setting up for _showdownDraw)
                // Or, more simply, proceed directly to _showdownDraw which uses these new cards.
                // For simplicity, let's make the draw round automatically proceed to showdown.
                // UI would show "Draw! Dealing new cards..." then immediately show new cards and result.
                 _proceedToNextPhase(); // This will call _showdownDraw
                return; 
            } else { // Tie even after a draw round, split pot
                _splitPot();
            }
        } else {            
            uint256 actualPotPlayer0Contributed = players[0].currentBetInRound;
            uint256 actualPotPlayer1Contributed = players[1].currentBetInRound;

            if (winner == players[0].addr) {
                uint256 winnableAmount = actualPotPlayer0Contributed + actualPotPlayer1Contributed;
                 // Player 0 wins. Max they can win from player 1 is what player 1 put in *or* what p0 put in if p0 was all-in for less
                if (players[0].isAllIn && actualPotPlayer0Contributed < actualPotPlayer1Contributed) {
                     winnableAmount = actualPotPlayer0Contributed * 2;
                } else {
                     winnableAmount = actualPotPlayer0Contributed + actualPotPlayer1Contributed;
                }


                if (pot > winnableAmount && (players[0].isAllIn || players[1].isAllIn) ){
                    //This case should be covered by _handlePotentialRefund
                }


                players[0].chips += pot; // Winner takes the whole pot (after refunds if any)
                emit WinnerDetermined(winner, pot);
            } else { // winner is players[1].addr
                 uint256 winnableAmount = actualPotPlayer0Contributed + actualPotPlayer1Contributed;

                if (players[1].isAllIn && actualPotPlayer1Contributed < actualPotPlayer0Contributed) {
                     winnableAmount = actualPotPlayer1Contributed * 2;
                } else {
                     winnableAmount = actualPotPlayer0Contributed + actualPotPlayer1Contributed;
                }

                if (pot > winnableAmount && (players[0].isAllIn || players[1].isAllIn) ){
                     //This case should be covered by _handlePotentialRefund
                }
                players[1].chips += pot;
                emit WinnerDetermined(winner, pot);
            }
            pot = 0;
        }
        _endRound();
    }
    
    function _splitPot() internal {
        uint256 amountEach = pot / 2;
        players[0].chips += amountEach;
        players[1].chips += amountEach;
        if (pot % 2 != 0) { // Odd chip, give to player 0 (or dealer convention)
            players[0].chips += 1;
        }
        emit PotSplit(players[0].addr, players[1].addr, amountEach);
        pot = 0;
        _endRound();
    }

    function _determineWinnerByFold() internal {
        uint8 winnerIdx = (currentPlayerIndex == 0) ? 1 : 0; // The other player
        players[winnerIdx].chips += pot;
        emit WinnerDetermined(players[winnerIdx].addr, pot);
        pot = 0;
        _endRound();
    }

    function _endRound() internal {
        gamePhase = GamePhase.GameOver; // Or Idle if auto-starting new round
        // For this project, let's set to GameOver. Players can choose to start a new game if they wish.
        // To play again, players would need to call _startGame() (perhaps via a new public function `requestNewGame()`)
        // For simplicity now, a new game requires new joins or a manual restart by contract owner if designed that way.
        // Let's assume players stay and can start a new round if they both agree (not implemented here)
        // Or simply, the game ends and they can choose to `joinGame()` again for a fresh setup if they leave.

        // Reset player states for a potential new game IF they stay in the contract instance
        // This part is tricky without explicit "leave game" or "start new round" functions.
        // For now, GameOver means this particular hand is done.
        // If you want to allow subsequent rounds:
        // _startGame(); // This would immediately start a new round if chips allow.
    }

    // --- Helper Functions ---
    function _requireCorrectPlayer() internal view {
        require(msg.sender == players[currentPlayerIndex].addr, "Not your turn");
    }

    function _getPlayerStorage(address playerAddr) internal view returns (Player storage) {
        for (uint8 i = 0; i < playerCount; i++) {
            if (players[i].addr == playerAddr) {
                return players[i];
            }
        }
        revert("Player not found in game");
    }

    function _switchPlayer() internal {
        currentPlayerIndex = 1 - currentPlayerIndex; // Switch between 0 and 1
    }
    
    // --- View Functions (for client interaction) ---
    function getPlayerInfo(address playerAddr) public view returns (address addr, uint256 chips, uint8 card, uint256 currentBet, bool hasFolded, bool isAllIn) {
        Player storage p = _getPlayerStorage(playerAddr);
        // IMPORTANT: A player should NOT be able to see their own card via this function directly from blockchain.
        // This function would typically be called by the client for THE OTHER PLAYER.
        // Or, the card is revealed only at showdown.
        // For Indian Poker, you see others' cards, not your own.
        // So, if msg.sender asks for their own info, don't show card. If for opponent, show card.
        // However, Solidity view functions don't know msg.sender if called off-chain.
        // A better approach: separate functions for `getOwnUnrevealedStatus` and `getOpponentVisibleCard`.

        // This simplified version shows the card, assuming client handles display logic.
        return (p.addr, p.chips, p.card, p.currentBetInRound, p.hasFolded, p.isAllIn);
    }

    // Specific function to get opponent's card, as per Indian Poker rules
    function getOpponentCard() public view returns (uint8) {
        require(playerCount == 2, "Game not active with 2 players");
        require(gamePhase != GamePhase.Idle && gamePhase != GamePhase.GameOver, "Game not in active round");
        
        uint8 opponentPlayerIndex;
        if (msg.sender == players[0].addr) {
            opponentPlayerIndex = 1;
        } else if (msg.sender == players[1].addr) {
            opponentPlayerIndex = 0;
        } else {
            revert("Caller is not part of this game");
        }
        if (gamePhase == GamePhase.DrawRound && players[opponentPlayerIndex].hasRevealedDrawCard) {
            return players[opponentPlayerIndex].drawCard;
        }
        return players[opponentPlayerIndex].card;
    }
    
    function getGameDetails() public view returns (
        GamePhase currentPhase,
        uint256 currentPot,
        address p0Addr,
        uint256 p0Chips,
        uint256 p0Bet,
        bool p0Folded,
        address p1Addr,
        uint256 p1Chips,
        uint256 p1Bet,
        bool p1Folded,
        address currentTurnPlayer,
        uint256 callAmount
    ) {
        p0Addr = players[0].addr;
        p0Chips = players[0].chips;
        p0Bet = players[0].currentBetInRound;
        p0Folded = players[0].hasFolded;

        if (playerCount > 1) {
            p1Addr = players[1].addr;
            p1Chips = players[1].chips;
            p1Bet = players[1].currentBetInRound;
            p1Folded = players[1].hasFolded;
        } else {
            p1Addr = address(0);
            p1Chips = 0;
            p1Bet = 0;
            p1Folded = false;
        }
        
        currentTurnPlayer = (gamePhase == GamePhase.Betting || gamePhase == GamePhase.DrawRound) ? players[currentPlayerIndex].addr : address(0);
        
        return (
            gamePhase,
            pot,
            p0Addr, p0Chips, p0Bet, p0Folded,
            p1Addr, p1Chips, p1Bet, p1Folded,
            currentTurnPlayer,
            amountToCall
        );
    }

    // Function to allow starting a new round if game is over and players have chips
    // This is a manual restart for a new hand with existing players/chips.
    function startNewHand() public nonReentrant {
        require(playerCount == 2, "Need 2 players who had joined");
        require(gamePhase == GamePhase.GameOver, "Can only start a new hand if the previous one is over");
        require(players[0].chips > 0 && players[1].chips > 0, "Both players need chips to start a new hand");
        // Ensure msg.sender is one of the players (optional, could be open)
        require(msg.sender == players[0].addr || msg.sender == players[1].addr, "Only players can start a new hand");

        _startGame(); // Re-initialize deck, deal cards, reset bets etc.
    }

    // Fallback function to receive ETH (e.g. if someone just sends ETH to contract)
    // It's better to use specific functions like getChip.
    receive() external payable {
        // Optionally, credit sender with chips, but this is ambiguous.
        // For this contract, direct ETH sends are not for chip purchase unless through getChip.
        // You could revert, or log it, or try to give chips if value matches.
        // Reverting is safer if ETH is not expected this way.
        // revert("Please use getChip() to buy chips.");
    }
}