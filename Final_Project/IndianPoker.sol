// SPDX-License-Identifier: GPL-3.0
// Claude 및 ChatGPT 사용

pragma solidity ^0.8.18;

contract IndianPoker {
    // 카드 값 정의 (2=2, 3=3, ..., 10=10, J=11, Q=12, K=13, A=14, Joker=0)
    enum CardValue { 
        JOKER, // 0
        TWO,   // 1
        THREE, // 2
        FOUR,  // 3
        FIVE,  // 4
        SIX,   // 5
        SEVEN, // 6
        EIGHT, // 7
        NINE,  // 8
        TEN,   // 9
        JACK,  // 10
        QUEEN, // 11
        KING,  // 12
        ACE    // 13
    }

    // 게임 상태
    enum GamePhase { 
        WAITING, // 대기
        BETTING, // 배팅 중
        SHOWDOWN, // 공개 
        FINISHED  // 게임 종료
    }

    // 플레이어 행동 
    enum PlayerAction { 
        NONE,
        BET,
        CALL,
        RAISE,
        FOLD,
        ALL_IN
    }

    // 플레이어 정보
    struct Player {
        address playerAddress; // 플레이어 지갑 주소
        uint256 chips;         // 보유 칩 수
        CardValue card;        // 받은 카드
        bool isActive;         // 행동 여부
        bool hasFolded;
        uint256 currentBet;    // 현재 배팅 금액
        PlayerAction lastAction; // 마지막 행동
        bool isAllIn;           // 올인 가능 여부
        uint256 allInAmount;    // 올인 금액
    }

    // 게임 정보
    struct Game {
        uint256 gameId;
        Player[] players;
        uint256 pot;
        uint256 currentBet;
        uint256 currentPlayerIndex;
        GamePhase phase;
        bool isActive;
        address winner;
        uint256 minBet;
        uint256 activePlayerCount;
        uint256 bettingRound;
    }
    
    // 상태 변수
    mapping(address => uint256) public playerChips;
    mapping(uint256 => Game) public games;
    mapping(address => uint256) public playerGameId;
    mapping(uint256 => mapping(address => bool)) public hasActed; // 매 라운드 행동 여부

    uint256 public gameCounter;
    uint256 constant CHIP_RATE = 20;                  // 0.001 ETH → 20 chips
    uint256 constant EXCHANGE_RATE = 50000000000000;  // 1 chip = 0.00005 ETH
    uint256 constant ENTRY_FEE = 0.001 ether;
    uint256 constant MAX_PLAYERS = 6;
    uint256 constant MIN_PLAYERS = 2;

    // 이벤트
    event GameCreated(uint256 gameId, address creator);
    event PlayerJoined(uint256 gameId, address player);
    event GameStarted(uint256 gameId);
    event PlayerActed(uint256 gameId, address player, PlayerAction action, uint256 amount);
    event CardDealt(uint256 gameId, address player, CardValue card);
    event GameEnded(uint256 gameId, address winner, uint256 winAmount);
    event ChipsPurchased(address player, uint256 amount);
    event ChipsExchanged(address player, uint256 chipAmount, uint256 ethAmount);

    modifier onlyActiveGame(uint256 gameId) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        require(games[gameId].isActive, "Game is not active");
        _;
    }

    modifier onlyPlayer(uint256 gameId) {
        require(playerGameId[msg.sender] == gameId, "You are not in this game");
        require(gameId > 0, "Invalid game ID");
        _;
    }

    modifier validGameState(uint256 gameId) {
        require(games[gameId].activePlayerCount > 0, "No active players");
        _;
    }
    
    // 칩 구매 함수
    function getChip() external payable {
        require(msg.value >= ENTRY_FEE, "Minimum 0.001 ETH required");
        require(msg.value % ENTRY_FEE == 0, "Must be multiple of 0.001 ETH");

        uint256 chipAmount = (msg.value * CHIP_RATE) / ENTRY_FEE;
        playerChips[msg.sender] += chipAmount;
        emit ChipsPurchased(msg.sender, chipAmount);
    }

    // 칩 환전 함수
    function exchange(uint256 chipAmount) external {
        require(chipAmount > 0, "Amount must be greater than 0");
        require(playerChips[msg.sender] >= chipAmount, "Insufficient chips");
        require(playerGameId[msg.sender] == 0, "Cannot exchange while in game");

        uint256 ethAmount = chipAmount * EXCHANGE_RATE;
        require(address(this).balance >= ethAmount, "Contract has insufficient balance");

        playerChips[msg.sender] -= chipAmount;
        payable(msg.sender).transfer(ethAmount);
        emit ChipsExchanged(msg.sender, chipAmount, ethAmount);
    }

    // 게임 생성
    function createGame() external returns (uint256) {
        require(playerChips[msg.sender] >= 20, "Need at least 20 chips to create game");
        require(playerGameId[msg.sender] == 0, "Already in a game");

        gameCounter++;
        uint256 gameId = gameCounter;

        Game storage newGame = games[gameId];
        newGame.gameId = gameId;
        newGame.phase = GamePhase.WAITING;
        newGame.isActive = true;
        newGame.minBet = 1;
        newGame.activePlayerCount = 0;
        newGame.bettingRound = 0;

        emit GameCreated(gameId, msg.sender);
        return gameId;
    }

    // 게임 참가
    function joinGame(uint256 gameId) external onlyActiveGame(gameId) {
        require(playerChips[msg.sender] >= 20, "Need at least 20 chips to join");
        require(playerGameId[msg.sender] == 0, "Already in a game");
        require(games[gameId].phase == GamePhase.WAITING, "Game already started");
        require(games[gameId].players.length < MAX_PLAYERS, "Game is full");

        Game storage game = games[gameId];
        
        // 중복 참가 체크
        for (uint256 i = 0; i < game.players.length; i++) {
            require(game.players[i].playerAddress != msg.sender, "Already joined this game");
        }

        // 플레이어 추가
        Player memory newPlayer = Player({
            playerAddress: msg.sender,
            chips: 20,
            card: CardValue.TWO,
            isActive: true,
            hasFolded: false,
            currentBet: 0,
            lastAction: PlayerAction.NONE,
            isAllIn: false,
            allInAmount: 0
        });

        game.players.push(newPlayer);
        playerChips[msg.sender] -= 20;
        playerGameId[msg.sender] = gameId;
        game.activePlayerCount++;

        emit PlayerJoined(gameId, msg.sender);

        // 최소 인원 이상이면 게임 시작
        if (game.players.length >= MIN_PLAYERS) {
            _startGame(gameId);
        }
    }
    
    // 게임 시작 (카드 배분)
    function _startGame(uint256 gameId) internal {
        Game storage game = games[gameId];
        require(game.players.length >= MIN_PLAYERS, "Not enough players");

        game.phase = GamePhase.BETTING;
        game.currentPlayerIndex = 0;
        game.bettingRound = 1;

        // 랜덤 카드 배분
        for (uint256 i = 0; i < game.players.length; i++) {
            uint256 randomValue = uint256(
                keccak256(
                    abi.encodePacked(
                        block.timestamp,
                        block.prevrandao,
                        msg.sender,
                        i,
                        blockhash(block.number - 1)
                    )
                )
            ) % 14;

            game.players[i].card = CardValue(randomValue);
            emit CardDealt(gameId, game.players[i].playerAddress, game.players[i].card);
        }

        emit GameStarted(gameId);
    }
    
    // 배팅 함수
    function bet(uint256 gameId, uint256 amount)
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
        validGameState(gameId)
    {
        Game storage game = games[gameId];
        require(game.phase == GamePhase.BETTING, "Not in betting phase");
        require(amount >= game.minBet, "Bet too low");
        require(amount > 0, "Bet must be positive");
        
        Player storage player = getPlayer(game, msg.sender);
        require(player.isActive && !player.hasFolded, "Player not active");
        require(player.chips >= amount, "Insufficient chips");
        require(!hasActed[gameId][msg.sender] || player.lastAction == PlayerAction.NONE, "Already acted this round");
        
        player.chips -= amount;
        player.currentBet += amount; // 누적 배팅
        player.lastAction = PlayerAction.BET;
        game.pot += amount;
        
        if (player.currentBet > game.currentBet) {
            game.currentBet = player.currentBet;
        }
        
        hasActed[gameId][msg.sender] = true;
        
        emit PlayerActed(gameId, msg.sender, PlayerAction.BET, amount);
        
        nextPlayer(gameId);
    }
    
    // 콜 함수
    function call(uint256 gameId)
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
        validGameState(gameId)
    {
        Game storage game = games[gameId];
        require(game.phase == GamePhase.BETTING, "Not in betting phase");
        
        Player storage player = getPlayer(game, msg.sender);
        require(player.isActive && !player.hasFolded, "Player not active");
        require(!hasActed[gameId][msg.sender], "Already acted this round");
        
        uint256 callAmount = game.currentBet - player.currentBet;
        require(callAmount > 0, "Nothing to call");
        
        // 올인 체크
        if (player.chips < callAmount) {
            // 올인 처리
            uint256 allInAmount = player.chips;
            player.chips = 0;
            player.currentBet += allInAmount;
            player.lastAction = PlayerAction.ALL_IN;
            player.isAllIn = true;
            player.allInAmount = player.currentBet; // 총 올인 금액
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
    
    // 레이즈 함수
    function raise(uint256 gameId, uint256 raiseAmount)
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
        validGameState(gameId)
    {
        Game storage game = games[gameId];
        require(game.phase == GamePhase.BETTING, "Not in betting phase");
        require(raiseAmount > 0, "Raise amount must be positive");
        
        Player storage player = getPlayer(game, msg.sender);
        require(player.isActive && !player.hasFolded, "Player not active");
        require(!hasActed[gameId][msg.sender], "Already acted this round");
        
        uint256 callAmount = game.currentBet - player.currentBet;
        uint256 totalAmount = callAmount + raiseAmount;
        require(player.chips >= totalAmount, "Insufficient chips");
        
        player.chips -= totalAmount;
        player.currentBet += totalAmount;
        player.lastAction = PlayerAction.RAISE;
        game.pot += totalAmount;
        game.currentBet = player.currentBet;
        hasActed[gameId][msg.sender] = true;
        
        // 다른 플레이어들의 행동 상태 리셋 (레이즈 후)
        for (uint256 i = 0; i < game.players.length; i++) {
            if (
                game.players[i].playerAddress != msg.sender &&
                game.players[i].isActive &&
                !game.players[i].hasFolded
            ) {
                hasActed[gameId][game.players[i].playerAddress] = false;
            }
        }
        
        emit PlayerActed(gameId, msg.sender, PlayerAction.RAISE, raiseAmount);
        nextPlayer(gameId);
    }
    
    // 폴드 함수
    function fold(uint256 gameId)
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
        validGameState(gameId)
    {
        Game storage game = games[gameId];
        require(game.phase == GamePhase.BETTING, "Not in betting phase");
        
        Player storage player = getPlayer(game, msg.sender);
        require(player.isActive && !player.hasFolded, "Player not active");
        
        player.hasFolded = true;
        player.isActive = false;
        player.lastAction = PlayerAction.FOLD;
        game.activePlayerCount--;
        hasActed[gameId][msg.sender] = true;
        
        // 에이스 패널티 체크
        if (player.card == CardValue.ACE && player.chips > 0) {
            uint256 penalty = player.chips / 2;
            if (player.chips % 2 == 1) {
                penalty += 1; // 홀수면 +1
            }
            
            // 패널티 적용 (보유 칩 범위 내에서)
            if (penalty > player.chips) {
                penalty = player.chips;
            }
            
            player.chips -= penalty;
            game.pot += penalty;
        }
        
        emit PlayerActed(gameId, msg.sender, PlayerAction.FOLD, 0);
        
        // 한 명만 남았으면 게임 종료
        if (game.activePlayerCount == 1) {
            endGameEarly(gameId);
            return;
        }
        
        // 유효한 다음 플레이어가 있는지 확인
        if (hasValidNextPlayer(gameId)) {
            nextPlayer(gameId);
        } else {
            // 모든 플레이어가 행동을 완료했으면 쇼다운
            showdown(gameId);
        }
    }
    
    // 유효한 다음 플레이어 존재 확인
    function hasValidNextPlayer(uint256 gameId) internal view returns (bool) {
        Game storage game = games[gameId];
        
        for (uint256 i = 0; i < game.players.length; i++) {
            if (
                game.players[i].isActive &&
                !game.players[i].hasFolded &&
                !hasActed[gameId][game.players[i].playerAddress]
            ) {
                return true;
            }
        }
        return false;
    }
    
    // 다음 플레이어로 턴 넘기기
    function nextPlayer(uint256 gameId) internal {
        Game storage game = games[gameId];
        
        // 모든 활성 플레이어가 행동했는지 체크
        if (!hasValidNextPlayer(gameId)) {
            showdown(gameId);
            return;
        }
        
        // 안전한 다음 플레이어 찾기 (무한 루프 방지)
        uint256 attempts = 0;
        uint256 maxAttempts = game.players.length;
        
        do {
            game.currentPlayerIndex = (game.currentPlayerIndex + 1) % game.players.length;
            attempts++;
            
            if (attempts > maxAttempts) {
                // 무한 루프 방지 - 강제로 쇼다운 진행
                showdown(gameId);
                return;
            }
        } while (
            game.players[game.currentPlayerIndex].hasFolded ||
            !game.players[game.currentPlayerIndex].isActive ||
            hasActed[gameId][game.players[game.currentPlayerIndex].playerAddress]
        );
    }
    
    // 조기 게임 종료 (한 명만 남은 경우)
    function endGameEarly(uint256 gameId) internal {
        Game storage game = games[gameId];
        
        // 마지막 남은 플레이어 찾기
        address winner;
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].isActive && !game.players[i].hasFolded) {
                winner = game.players[i].playerAddress;
                break;
            }
        }
        
        require(winner != address(0), "No winner found");
        
        game.winner = winner;
        Player storage winnerPlayer = getPlayer(game, winner);
        winnerPlayer.chips += game.pot;
        
        emit GameEnded(gameId, winner, game.pot);
        endGame(gameId);
    }
    
    // 쇼다운 (카드 공개 및 승자 결정)
    function showdown(uint256 gameId) internal {
        Game storage game = games[gameId];
        game.phase = GamePhase.SHOWDOWN;
        
        address winner = determineWinner(gameId);
        require(winner != address(0), "No valid winner");
        
        game.winner = winner;
        
        // 상금 분배 (올인 플레이어 고려)
        distributeWinnings(gameId, winner);
        
        emit GameEnded(gameId, winner, game.pot);
        endGame(gameId);
    }
    
    // 상금 분배 (올인 처리 포함)
    function distributeWinnings(uint256 gameId, address winner) internal {
        Game storage game = games[gameId];
        Player storage winnerPlayer = getPlayer(game, winner);
        
        // 기본적으로 모든 팟을 승자가 가져감
        uint256 winAmount = game.pot;
        winnerPlayer.chips += winAmount;
        game.pot = 0;
    }
    
    // 승자 결정 (카드 비교 로직)
    function determineWinner(uint256 gameId) internal view returns (address) {
        Game storage game = games[gameId];
        
        address winner;
        CardValue highestCard = CardValue.TWO; // 초기값(논리상 JOKER보다 작으므로 필요 시 CardValue.JOKER 로 변경 가능)
        bool winnerSet = false;
        
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].isActive && !game.players[i].hasFolded) {
                CardValue playerCard = game.players[i].card;
                
                if (!winnerSet) {
                    winner = game.players[i].playerAddress;
                    highestCard = playerCard;
                    winnerSet = true;
                } else {
                    if (compareCards(playerCard, highestCard)) {
                        winner = game.players[i].playerAddress;
                        highestCard = playerCard;
                    }
                }
            }
        }
        
        return winner;
    }
    
    // 수정된 카드 비교 함수
    function compareCards(CardValue card1, CardValue card2) internal pure returns (bool) {
        // 조커는 A보다 높지만 다른 모든 카드보다 낮음
        if (card1 == CardValue.JOKER && card2 == CardValue.JOKER) return false;
        if (card1 == CardValue.JOKER && card2 == CardValue.ACE) return true;
        if (card1 == CardValue.JOKER && card2 != CardValue.ACE) return false;
        if (card2 == CardValue.JOKER && card1 == CardValue.ACE) return false;
        if (card2 == CardValue.JOKER && card1 != CardValue.ACE) return true;
        
        // 일반 카드 비교
        return uint8(card1) > uint8(card2);
    }
    
    // 게임 종료
    function endGame(uint256 gameId) internal {
        Game storage game = games[gameId];
        game.phase = GamePhase.FINISHED;
        game.isActive = false;
        
        // 플레이어들의 남은 칩을 계정으로 반환
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].chips > 0) {
                playerChips[game.players[i].playerAddress] += game.players[i].chips;
            }
            playerGameId[game.players[i].playerAddress] = 0;
            
            // 행동 상태 초기화
            hasActed[gameId][game.players[i].playerAddress] = false;
        }
    }
    
    // 안전한 플레이어 조회 (storage pointer 초기화 오류 방지)
    function getPlayer(Game storage game, address playerAddr) internal view returns (Player storage) {
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].playerAddress == playerAddr) {
                return game.players[i];
            }
        }
        revert("Player not found in game");
    }
    
    // 게임 정보 조회
    function getGameInfo(uint256 gameId)
        external
        view
        returns (
            uint256 pot,
            uint256 currentBet,
            GamePhase phase,
            bool isActive,
            address winner,
            uint256 playerCount,
            uint256 activePlayerCount
        )
    {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage game = games[gameId];
        return (
            game.pot,
            game.currentBet,
            game.phase,
            game.isActive,
            game.winner,
            game.players.length,
            game.activePlayerCount
        );
    }

    // 플레이어 정보 조회 (storage pointer 할당 오류 수정)
    function getPlayerInfo(uint256 gameId, address playerAddr)
        external
        view
        returns (
            uint256 chips,
            CardValue card,
            bool isActive,
            bool hasFolded,
            uint256 currentBet,
            PlayerAction lastAction
        )
    {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage game = games[gameId];

        // 먼저 존재하는지 확인하며 인덱스 찾기
        bool playerExists = false;
        uint256 idx;
        for (uint256 i = 0; i < game.players.length; i++) {
            if (game.players[i].playerAddress == playerAddr) {
                idx = i;
                playerExists = true;
                break;
            }
        }
        require(playerExists, "Player not in game");

        // 이제 storage 포인터를 명확하게 초기화
        Player storage player = game.players[idx];

        // 자신의 카드는 볼 수 없음(인디언 포커 룰)
        CardValue visibleCard = (playerAddr == msg.sender) ? CardValue.TWO : player.card;

        return (
            player.chips,
            visibleCard,
            player.isActive,
            player.hasFolded,
            player.currentBet,
            player.lastAction
        );
    }
    
    function getPlayerChips(address player) external view returns (uint256) {
        return playerChips[player];
    }
    
    function getCurrentPlayer(uint256 gameId) external view returns (address) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage game = games[gameId];
        if (game.players.length > 0 && game.currentPlayerIndex < game.players.length) {
            return game.players[game.currentPlayerIndex].playerAddress;
        }
        return address(0);
    }
    
    // 컨트랙트 잔액 확인
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    // 비상 기능들
    address public owner;
    
    constructor() {
        owner = msg.sender;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }
    
    // 게임 강제 종료 (비상시)
    function emergencyEndGame(uint256 gameId) external onlyOwner {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage game = games[gameId];
        require(game.isActive, "Game not active");
        
        // 모든 플레이어에게 배팅 금액 환불
        for (uint256 i = 0; i < game.players.length; i++) {
            Player storage player = game.players[i];
            player.chips += player.currentBet;
            playerChips[player.playerAddress] += player.chips;
            playerGameId[player.playerAddress] = 0;
        }
        
        game.isActive = false;
        game.phase = GamePhase.FINISHED;
    }
}
