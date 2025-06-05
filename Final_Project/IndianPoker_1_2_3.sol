// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

contract IndianPoker {
    enum CardValue { JOKER, TWO, THREE, FOUR, FIVE, SIX, SEVEN, EIGHT, NINE, TEN, JACK, QUEEN, KING, ACE }
    enum GamePhase { WAITING, BETTING, FINISHED }
    enum PlayerAction { NONE, BET, CALL, RAISE, FOLD, ALL_IN }

    struct Player {
        address addr;
        uint256 chips;
        CardValue card;
        bool isActive;
        bool hasFolded;
        uint256 currentBet;
        PlayerAction lastAction;
    }

    struct Game {
        uint256 gameId;
        Player[] players;
        uint256 pot;
        uint256 currentBet;
        uint256 currentPlayerIndex;
        GamePhase phase;
        bool isActive;
        address winner;
        uint256 activePlayerCount;
    }
    
    mapping(address => uint256) public playerChips;
    mapping(uint256 => Game) public games;
    mapping(address => uint256) public playerGameId;
    mapping(uint256 => mapping(address => bool)) public hasActed;

    uint256 public gameCounter;
    uint256 constant CHIP_RATE = 20;
    uint256 constant EXCHANGE_RATE = 50000000000000;
    uint256 constant ENTRY_FEE = 0.001 ether;
    uint256 constant MAX_PLAYERS = 6;
    uint256 constant MIN_PLAYERS = 2;
    
    address public owner;
    
    event GameCreated(uint256 gameId, address creator);
    event PlayerJoined(uint256 gameId, address player);
    event GameStarted(uint256 gameId);
    event PlayerActed(uint256 gameId, address player, PlayerAction action, uint256 amount);
    event CardDealt(uint256 gameId, address player, CardValue card);
    event GameEnded(uint256 gameId, address winner, uint256 winAmount);
    event ChipsPurchased(address player, uint256 amount);
    event ChipsExchanged(address player, uint256 chipAmount, uint256 ethAmount);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyActiveGame(uint256 gameId) {
        require(gameId > 0 && gameId <= gameCounter && games[gameId].isActive, "Invalid or inactive game");
        _;
    }

    modifier onlyPlayer(uint256 gameId) {
        require(playerGameId[msg.sender] == gameId && gameId > 0, "Not in this game");
        _;
    }

    modifier canAct(uint256 gameId) {
        Game storage game = games[gameId];
        require(game.phase == GamePhase.BETTING, "Not in betting phase");
        Player storage player = getPlayer(game, msg.sender);
        require(player.isActive && !player.hasFolded && !hasActed[gameId][msg.sender], "Cannot act");
        _;
    }
    
    // 칩 구매
    function getChip() external payable {
        require(msg.value >= ENTRY_FEE && msg.value % ENTRY_FEE == 0, "Invalid amount");
        uint256 chipAmount = (msg.value * CHIP_RATE) / ENTRY_FEE;
        playerChips[msg.sender] += chipAmount;
        emit ChipsPurchased(msg.sender, chipAmount);
    }

    // 칩 환전
    function exchange(uint256 chipAmount) external {
        require(chipAmount > 0 && playerChips[msg.sender] >= chipAmount && playerGameId[msg.sender] == 0, "Invalid exchange");
        uint256 ethAmount = chipAmount * EXCHANGE_RATE;
        require(address(this).balance >= ethAmount, "Insufficient contract balance");
        
        playerChips[msg.sender] -= chipAmount;
        payable(msg.sender).transfer(ethAmount);
        emit ChipsExchanged(msg.sender, chipAmount, ethAmount);
    }

    // 게임 생성
    function createGame() external returns (uint256) {
        require(playerChips[msg.sender] >= 20 && playerGameId[msg.sender] == 0, "Cannot create game");
        
        gameCounter++;
        Game storage newGame = games[gameCounter];
        newGame.gameId = gameCounter;
        newGame.phase = GamePhase.WAITING;
        newGame.isActive = true;
        
        emit GameCreated(gameCounter, msg.sender);
        return gameCounter;
    }

    // 게임 참가
    function joinGame(uint256 gameId) external onlyActiveGame(gameId) {
        require(playerChips[msg.sender] >= 20 && playerGameId[msg.sender] == 0, "Cannot join");
        Game storage game = games[gameId];
        require(game.phase == GamePhase.WAITING && game.players.length < MAX_PLAYERS, "Cannot join game");
        
        // 중복 참가 체크
        for (uint256 i = 0; i < game.players.length; i++) {
            require(game.players[i].addr != msg.sender, "Already joined");
        }

        game.players.push(Player({
            addr: msg.sender,
            chips: playerChips[msg.sender],
            card: CardValue.TWO,
            isActive: true,
            hasFolded: false,
            currentBet: 0,
            lastAction: PlayerAction.NONE
        }));
        
        playerGameId[msg.sender] = gameId;
        game.activePlayerCount++;
        emit PlayerJoined(gameId, msg.sender);
    }

    // 게임 시작
    function startGame(uint256 gameId) external onlyOwner {
        Game storage game = games[gameId];
        require(game.players.length >= MIN_PLAYERS, "Not enough players");

        game.phase = GamePhase.BETTING;
        game.currentPlayerIndex = 0;

        // 참가비 징수 및 카드 배분
        for (uint256 i = 0; i < game.players.length; i++) {
            playerChips[game.players[i].addr] -= 1;
            game.players[i].chips = 1;
            game.pot += 1;
            
            // 랜덤 카드 배분
            uint256 randomValue = uint256(keccak256(abi.encodePacked(
                block.timestamp, block.prevrandao, msg.sender, i, blockhash(block.number - 1)
            ))) % 14;
            game.players[i].card = CardValue(randomValue);
            
            if(game.players[i].addr != msg.sender) {
                emit CardDealt(gameId, game.players[i].addr, game.players[i].card);
            }
        }

        emit GameStarted(gameId);
    }

    // 배팅
    function bet(uint256 gameId, uint256 amount) external onlyActiveGame(gameId) onlyPlayer(gameId) canAct(gameId) {
        Game storage game = games[gameId];
        Player storage player = getPlayer(game, msg.sender);
        require(amount > 0 && player.chips >= amount, "Invalid bet amount");
        
        player.chips -= amount;
        player.currentBet += amount;
        player.lastAction = PlayerAction.BET;
        game.pot += amount;
        
        if (player.currentBet > game.currentBet) {
            game.currentBet = player.currentBet;
        }
        
        hasActed[gameId][msg.sender] = true;
        emit PlayerActed(gameId, msg.sender, PlayerAction.BET, amount);
        nextPlayer(gameId);
    }
    
    // 콜
    function call(uint256 gameId) external onlyActiveGame(gameId) onlyPlayer(gameId) canAct(gameId) {
        Game storage game = games[gameId];
        Player storage player = getPlayer(game, msg.sender);
        uint256 callAmount = game.currentBet - player.currentBet;
        require(callAmount > 0, "Nothing to call");
        
        if (player.chips < callAmount) {
            // 올인
            uint256 allInAmount = player.chips;
            player.chips = 0;
            player.currentBet += allInAmount;
            player.lastAction = PlayerAction.ALL_IN;
            game.pot += allInAmount;
            emit PlayerActed(gameId, msg.sender, PlayerAction.ALL_IN, allInAmount);
        } else {
            // 일반 콜
            player.chips -= callAmount;
            player.currentBet = game.currentBet;
            player.lastAction = PlayerAction.CALL;
            game.pot += callAmount;
            emit PlayerActed(gameId, msg.sender, PlayerAction.CALL, callAmount);
        }
        
        hasActed[gameId][msg.sender] = true;
        nextPlayer(gameId);
    }
    
    // 레이즈
    function raise(uint256 gameId, uint256 raiseAmount) external onlyActiveGame(gameId) onlyPlayer(gameId) canAct(gameId) {
        Game storage game = games[gameId];
        Player storage player = getPlayer(game, msg.sender);
        uint256 callAmount = game.currentBet - player.currentBet;
        uint256 totalAmount = callAmount + raiseAmount;
        require(raiseAmount > 0 && player.chips >= totalAmount, "Invalid raise");
        
        player.chips -= totalAmount;
        player.currentBet += totalAmount;
        player.lastAction = PlayerAction.RAISE;
        game.pot += totalAmount;
        game.currentBet = player.currentBet;
        hasActed[gameId][msg.sender] = true;
        
        // 다른 플레이어 행동 상태 리셋
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].addr != msg.sender && game.players[i].isActive && !game.players[i].hasFolded) {
                hasActed[gameId][game.players[i].addr] = false;
            }
        }
        
        emit PlayerActed(gameId, msg.sender, PlayerAction.RAISE, raiseAmount);
        nextPlayer(gameId);
    }
    
    // 폴드
    function fold(uint256 gameId) external onlyActiveGame(gameId) onlyPlayer(gameId) canAct(gameId) {
        Game storage game = games[gameId];
        Player storage player = getPlayer(game, msg.sender);
        
        player.hasFolded = true;
        player.isActive = false;
        player.lastAction = PlayerAction.FOLD;
        game.activePlayerCount--;
        hasActed[gameId][msg.sender] = true;
        
        // 에이스 패널티
        if (player.card == CardValue.ACE && player.chips > 0) {
            uint256 penalty = (player.chips + 1) / 2; // 올림 처리
            player.chips -= penalty;
            game.pot += penalty;
        }
        
        emit PlayerActed(gameId, msg.sender, PlayerAction.FOLD, 0);
        
        if (game.activePlayerCount == 1) {
            endGameEarly(gameId);
        } else if (hasValidNextPlayer(gameId)) {
            nextPlayer(gameId);
        } else {
            showdown(gameId);
        }
    }
    
    // 다음 플레이어 턴
    function nextPlayer(uint256 gameId) internal {
        Game storage game = games[gameId];
        
        if (!hasValidNextPlayer(gameId)) {
            showdown(gameId);
            return;
        }
        
        uint256 attempts = 0;
        do {
            game.currentPlayerIndex = (game.currentPlayerIndex + 1) % game.players.length;
            attempts++;
            if (attempts > game.players.length) {
                showdown(gameId);
                return;
            }
        } while (
            game.players[game.currentPlayerIndex].hasFolded ||
            !game.players[game.currentPlayerIndex].isActive ||
            hasActed[gameId][game.players[game.currentPlayerIndex].addr]
        );
    }
    
    function hasValidNextPlayer(uint256 gameId) internal view returns (bool) {
        Game storage game = games[gameId];
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].isActive && !game.players[i].hasFolded && !hasActed[gameId][game.players[i].addr]) {
                return true;
            }
        }
        return false;
    }
    
    // 조기 게임 종료
    function endGameEarly(uint256 gameId) internal {
        Game storage game = games[gameId];
        
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].isActive && !game.players[i].hasFolded) {
                game.winner = game.players[i].addr;
                game.players[i].chips += game.pot;
                break;
            }
        }
        
        emit GameEnded(gameId, game.winner, game.pot);
        endGame(gameId);
    }
    
    // 쇼다운
    function showdown(uint256 gameId) internal {
        Game storage game = games[gameId];
        address winner = determineWinner(gameId);
        game.winner = winner;
        
        Player storage winnerPlayer = getPlayer(game, winner);
        winnerPlayer.chips += game.pot;
        
        emit GameEnded(gameId, winner, game.pot);
        endGame(gameId);
    }
    
    // 승자 결정
    function determineWinner(uint256 gameId) internal view returns (address) {
        Game storage game = games[gameId];
        address winner;
        CardValue highestCard = CardValue.TWO;
        bool winnerSet = false;
        
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].isActive && !game.players[i].hasFolded) {
                if (!winnerSet || compareCards(game.players[i].card, highestCard)) {
                    winner = game.players[i].addr;
                    highestCard = game.players[i].card;
                    winnerSet = true;
                }
            }
        }
        
        return winner;
    }
    
    // 카드 비교
    function compareCards(CardValue card1, CardValue card2) internal pure returns (bool) {
        if (card1 == CardValue.JOKER && card2 == CardValue.JOKER) return false;
        if (card1 == CardValue.JOKER && card2 == CardValue.ACE) return true;
        if (card1 == CardValue.JOKER) return false;
        if (card2 == CardValue.JOKER && card1 == CardValue.ACE) return false;
        if (card2 == CardValue.JOKER) return true;
        
        return uint8(card1) > uint8(card2);
    }
    
    // 게임 종료
    function endGame(uint256 gameId) internal {
        Game storage game = games[gameId];
        game.phase = GamePhase.FINISHED;
        game.isActive = false;
        
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].chips > 0) {
                playerChips[game.players[i].addr] += game.players[i].chips;
            }
            hasActed[gameId][game.players[i].addr] = false;
        }
    }

    // 방 나가기
    function exitGame(uint256 gameId) external {
        require(games[gameId].phase == GamePhase.FINISHED, "Game not finished");
        
        Game storage game = games[gameId];
        game.isActive = false;
        for (uint256 i = 0; i < game.players.length; i++) {
            playerGameId[game.players[i].addr] = 0;
        }
    }
    
    // 헬퍼 함수
    function getPlayer(Game storage game, address playerAddr) internal view returns (Player storage) {
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].addr == playerAddr) {
                return game.players[i];
            }
        }
        revert("Player not found");
    }
    
    // 뷰 함수들
    function getMyChips() external view returns (uint256) {
        return playerChips[msg.sender];
    }
    
    function getGameInfo(uint256 gameId) external view returns (
        uint256 pot, uint256 currentBet, GamePhase phase, bool isActive, 
        address winner, uint256 playerCount, uint256 activePlayerCount
    ) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage game = games[gameId];
        return (game.pot, game.currentBet, game.phase, game.isActive, 
                game.winner, game.players.length, game.activePlayerCount);
    }

    function getPlayerInfo(uint256 gameId, address playerAddr) external view returns (
        uint256 chips, CardValue card, bool isActive, bool hasFolded, 
        uint256 currentBet, PlayerAction lastAction
    ) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage game = games[gameId];
        Player storage player = getPlayer(game, playerAddr);
        
        CardValue visibleCard = (playerAddr == msg.sender) ? CardValue.TWO : player.card;
        
        return (player.chips, visibleCard, player.isActive, 
                player.hasFolded, player.currentBet, player.lastAction);
    }
    
    function getCurrentPlayer(uint256 gameId) external view returns (address) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage game = games[gameId];
        if (game.players.length > 0 && game.currentPlayerIndex < game.players.length) {
            return game.players[game.currentPlayerIndex].addr;
        }
        return address(0);
    }
    
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    function checkCard(uint256 gameId) external onlyPlayer(gameId) {
        Game storage game = games[gameId];
        for (uint256 i = 0; i < game.players.length; i++) {
            if(game.players[i].addr != msg.sender) {
                emit CardDealt(gameId, game.players[i].addr, game.players[i].card);
            }
        }
    }
    
    // 비상 기능
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
    
    function emergencyEndGame(uint256 gameId) external onlyOwner {
        require(gameId > 0 && gameId <= gameCounter && games[gameId].isActive, "Invalid game");
        Game storage game = games[gameId];
        
        for (uint256 i = 0; i < game.players.length; i++) {
            Player storage player = game.players[i];
            player.chips += player.currentBet;
            playerChips[player.addr] += player.chips;
            playerGameId[player.addr] = 0;
        }
        
        game.isActive = false;
        game.phase = GamePhase.FINISHED;
    }
}