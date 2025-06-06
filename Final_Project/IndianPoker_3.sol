// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/*
  수정된 Indian Poker 컨트랙트
  - 룰:
    1) 각 플레이어는 joinGame() 호출 시 0.001 ETH를 지불하고 20칩을 받음
    2) createGame() 호출자가 해당 게임의 owner (방장) 이 됨
    3) 최소 2명, 최대 6명까지 참가 가능 (joinGame)
       - 참가하려면 항상 0.001 ETH를 보내야 함
    4) startGame()은 방장만 가능
       - 게임 시작 시 각 플레이어는 자동으로 1칩씩 팟에 배팅 (팟에 저장)
       - 카드 덱(1~10 각 2장, 총 20장) 셔플 후 각자 한 장씩 비공개로 배분
    5) 첫 플레이어가 첫 배팅(또는 폴드) → 다음 플레이어들은 call/raise/fold 가능
       - fold 시 카드가 10이면 패널티 5칩을 팟에 넣음
    6) 모두 call하면 showdown → 최고값 가진 플레이어 승리
       - 동점 시 tiedPlayers 간에 재드로우 시행 (덱에서 한 장씩 다시 뽑아 비교)
       - 승리자는 자신이 베팅한 금액만큼 회수, 나머지 팟 전부 가져감
       - 승리자가 다음 라운드 첫 플레이어
       - 덱이 소진되면 자동 재셔플
       - 한 사람이 모든 칩을 가졌으면 게임 종료
    7) exchange()로 게임 밖으로 칩 회수 가능
*/

contract IndianPoker {
    // ----------------------------------------
    // 1) enum / struct / 이벤트 / 상태 변수
    // ----------------------------------------

    enum CardValue {
        UNASSIGNED, // 0: 배정되지 않음
        ONE,        // 1
        TWO,        // 2
        THREE,      // 3
        FOUR,       // 4
        FIVE,       // 5
        SIX,        // 6
        SEVEN,      // 7
        EIGHT,      // 8
        NINE,       // 9
        TEN         // 10
    }

    enum GamePhase {
        WAITING,   // 대기 (플레이어 모으는 중)
        BETTING,   // 배팅 중
        SHOWDOWN,  // 카드 공개 & 승자 결정
        FINISHED   // 게임 종료
    }

    enum PlayerAction {
        NONE,
        BET,
        CALL,
        RAISE,
        FOLD,
        ALL_IN
    }

    struct Player {
        address addr;         // 플레이어 지갑 주소
        uint256 chips;        // 게임 머니(칩)
        uint8  card;          // 보유 카드 (1~10 배열 인덱스)
        bool   isActive;      // 아직 폴드/올인 등의 상태로 탈락 여부
        bool   hasFolded;     // 이번 판에서 폴드했는지
        uint256 currentBet;   // 이번 라운드에서 베팅한 총액
        PlayerAction lastAction;
        bool   isAllIn;       // 올인 상태
        uint256 allInAmount;  // 올인 당시 베팅 금액
    }

    struct Game {
        uint256 gameId;
        address owner;             // 방장
        Player[] players;          // 참가자 목록
        mapping(address => uint256) playerIndex; // 주소 → players 배열 인덱스 (1-based)
        uint256 pot;               // 팟 총액
        uint256 currentBet;        // 현재 highest 베팅 금액
        uint256 currentPlayerIdx;  // players 배열 내 현재 차례 인덱스
        GamePhase phase;           // 현재 게임 페이즈
        bool isActive;             // 게임이 진행 중인지
        uint256 minBet;            // 최소 베팅 단위
        uint256 activeCount;       // 현재 배팅 라운드에 남아있는 플레이어 수
        uint256 deckIndex;         // 덱에서 다음에 꺼낼 카드 인덱스
        uint8[] deck;              // 덱 저장
    }

    uint256 public gameCounter;
    mapping(uint256 => Game) private games;       // gameId → Game
    mapping(address => uint256) public playerGameId; // playerAddr → gameId
    mapping(address => uint256) public playerChips; // 총 보유 칩

    uint256 constant ENTRY_FEE = 0.001 ether;        // joinGame 시 반드시 전송
    uint256 constant MAX_PLAYERS = 6;
    uint256 constant MIN_PLAYERS = 2;

    event GameCreated(uint256 indexed gameId, address indexed owner);
    event PlayerJoined(uint256 indexed gameId, address indexed player);
    event GameStarted(uint256 indexed gameId);
    event PlayerActed(uint256 indexed gameId, address indexed player, PlayerAction action, uint256 amount);
    event Showdown(uint256 indexed gameId, address indexed winner, uint256 winAmount);
    event ChipsExchanged(address indexed player, uint256 chipAmount, uint256 ethAmount);
    event CardDealt(uint256 indexed gameId, address indexed player);

    modifier onlyGameOwner(uint256 gameId) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage g = games[gameId];
        require(msg.sender == g.owner, "Only game owner can call");
        _;
    }

    modifier onlyActiveGame(uint256 gameId) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage g = games[gameId];
        require(g.isActive, "Game is not active");
        _;
    }

    modifier onlyPlayer(uint256 gameId) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        require(playerGameId[msg.sender] == gameId, "You are not in this game");
        _;
    }

    modifier inPhase(uint256 gameId, GamePhase requiredPhase) {
        Game storage g = games[gameId];
        require(g.phase == requiredPhase, "Wrong game phase");
        _;
    }

    // ----------------------------------------
    // 2) 게임 생성/참가/시작
    // ----------------------------------------

    function createGame() external returns (uint256) {
        require(playerGameId[msg.sender] == 0, "Already in a game");

        gameCounter++;
        Game storage g = games[gameCounter];
        g.gameId = gameCounter;
        g.owner = msg.sender;
        g.phase = GamePhase.WAITING;
        g.isActive = true;
        g.minBet = 1;
        g.currentBet = 0;
        g.pot = 0;
        g.activeCount = 0;
        g.currentPlayerIdx = 0;

        emit GameCreated(gameCounter, msg.sender);
        return gameCounter;
    }

    function joinGame(uint256 gameId) external payable onlyActiveGame(gameId) {
        require(msg.value == ENTRY_FEE, "Must send exactly 0.001 ETH");
        Game storage g = games[gameId];
        require(g.phase == GamePhase.WAITING, "Game already started");
        require(g.players.length < MAX_PLAYERS, "Game is full");
        require(playerGameId[msg.sender] == 0, "Already in a game");

        require(g.playerIndex[msg.sender] == 0, "Already joined this game");

        Player memory p;
        p.addr = msg.sender;
        p.chips = 20;      // joinGame 시 20칩 지급
        p.card = 0;
        p.isActive = true;
        p.hasFolded = false;
        p.currentBet = 0;
        p.lastAction = PlayerAction.NONE;
        p.isAllIn = false;
        p.allInAmount = 0;

        g.players.push(p);
        g.playerIndex[msg.sender] = g.players.length;
        g.activeCount = g.players.length;
        playerGameId[msg.sender] = gameId;

        // 보유 총 칩에도 반영 (이미 p.chips=20이므로)
        playerChips[msg.sender] += 20;

        emit PlayerJoined(gameId, msg.sender);
    }

    function startGame(uint256 gameId)
        external
        onlyActiveGame(gameId)
        onlyGameOwner(gameId)
        inPhase(gameId, GamePhase.WAITING)
    {
        Game storage g = games[gameId];
        uint256 numPlayers = g.players.length;
        require(numPlayers >= MIN_PLAYERS, "Not enough players");

        // 각 플레이어가 1칩 안티
        for (uint256 i = 0; i < numPlayers; i++) {
            Player storage pl = g.players[i];
            require(pl.chips >= 1, "Player has insufficient chips");
            pl.chips -= 1;
            playerChips[pl.addr] -= 1;
            pl.currentBet = 1;
            g.pot += 1;
            pl.hasFolded = false;
            pl.isAllIn = false;
            pl.allInAmount = 0;
            pl.lastAction = PlayerAction.NONE;
            pl.isActive = true;
        }

        g.currentBet = 1;
        g.phase = GamePhase.BETTING;

        _initializeAndShuffleDeck(g);

        for (uint256 i = 0; i < numPlayers; i++) {
            uint8 dealt = _dealCard(g);
            g.players[i].card = dealt;
            emit CardDealt(gameId, g.players[i].addr);
        }

        emit GameStarted(gameId);
    }

    // ----------------------------------------
    // 3) 덱 관련 내부 함수
    // ----------------------------------------

    function _initializeAndShuffleDeck(Game storage g) internal {
        delete g.deck;
        g.deckIndex = 0;
        for (uint8 v = 1; v <= 10; v++) {
            g.deck.push(v);
            g.deck.push(v);
        }
        for (uint256 i = g.deck.length - 1; i > 0; i--) {
            uint256 j = uint256(
                keccak256(
                    abi.encodePacked(block.timestamp, block.prevrandao, i)
                )
            ) % (i + 1);
            uint8 temp = g.deck[i];
            g.deck[i] = g.deck[j];
            g.deck[j] = temp;
        }
    }

    function _dealCard(Game storage g) internal returns (uint8) {
        if (g.deckIndex >= g.deck.length) {
            _initializeAndShuffleDeck(g);
        }
        uint8 card = g.deck[g.deckIndex];
        g.deckIndex += 1;
        return card;
    }

    // ----------------------------------------
    // 4) 배팅 / 콜 / 레이즈 / 폴드 / 올인
    // ----------------------------------------

    function bet(uint256 gameId, uint256 amount)
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
    {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Not in betting phase");
        require(amount >= g.minBet, "Bet amount too low");
        require(amount > 0, "Bet amount must be positive");
        Player storage p = _getPlayerStorage(g, msg.sender);
        require(p.isActive && !p.hasFolded, "Player not active");
        require(!p.isAllIn, "Player is already all-in");
        require(p.lastAction == PlayerAction.NONE, "Already acted this round");

        uint256 toCall = g.currentBet > p.currentBet ? (g.currentBet - p.currentBet) : 0;
        uint256 totalCost = toCall + amount;
        require(p.chips >= totalCost, "Insufficient chips");

        if (toCall > 0) {
            p.chips -= toCall;
            playerChips[p.addr] -= toCall;
            p.currentBet += toCall;
            g.pot += toCall;
        }
        p.chips -= amount;
        playerChips[p.addr] -= amount;
        p.currentBet += amount;
        g.pot += amount;
        p.lastAction = PlayerAction.BET;

        if (p.currentBet > g.currentBet) {
            g.currentBet = p.currentBet;
            for (uint256 i = 0; i < g.players.length; i++) {
                if (i != g.playerIndex[msg.sender] - 1) {
                    if (g.players[i].isActive && !g.players[i].hasFolded && !g.players[i].isAllIn) {
                        g.players[i].lastAction = PlayerAction.NONE;
                    }
                }
            }
        }

        emit PlayerActed(gameId, msg.sender, PlayerAction.BET, amount + toCall);

        _advanceTurnOrShowdown(gameId);
    }

    function call(uint256 gameId)
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
    {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Not in betting phase");
        Player storage p = _getPlayerStorage(g, msg.sender);
        require(p.isActive && !p.hasFolded, "Player not active");
        require(!p.isAllIn, "Player is already all-in");
        require(p.lastAction == PlayerAction.NONE, "Already acted this round");

        uint256 toCall = g.currentBet > p.currentBet ? (g.currentBet - p.currentBet) : 0;
        require(toCall > 0, "Nothing to call");

        if (p.chips > toCall) {
            p.chips -= toCall;
            playerChips[p.addr] -= toCall;
            p.currentBet += toCall;
            g.pot += toCall;
            p.lastAction = PlayerAction.CALL;

            emit PlayerActed(gameId, msg.sender, PlayerAction.CALL, toCall);
        } else {
            uint256 allinAmt = p.chips;
            p.chips = 0;
            playerChips[p.addr] -= allinAmt;
            p.currentBet += allinAmt;
            g.pot += allinAmt;
            p.lastAction = PlayerAction.ALL_IN;
            p.isAllIn = true;
            p.allInAmount = p.currentBet;
            emit PlayerActed(gameId, msg.sender, PlayerAction.ALL_IN, allinAmt);

            if (p.currentBet > g.currentBet) {
                g.currentBet = p.currentBet;
                for (uint256 i = 0; i < g.players.length; i++) {
                    if (i != g.playerIndex[msg.sender] - 1) {
                        if (g.players[i].isActive && !g.players[i].hasFolded && !g.players[i].isAllIn) {
                            g.players[i].lastAction = PlayerAction.NONE;
                        }
                    }
                }
            }
        }

        _advanceTurnOrShowdown(gameId);
    }

    function raise(uint256 gameId, uint256 raiseAmount)
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
    {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Not in betting phase");
        Player storage p = _getPlayerStorage(g, msg.sender);
        require(p.isActive && !p.hasFolded, "Player not active");
        require(!p.isAllIn, "Player is already all-in");
        require(p.lastAction == PlayerAction.NONE, "Already acted this round");
        require(raiseAmount > 0, "Raise amount must be positive");

        uint256 toCall = g.currentBet > p.currentBet ? (g.currentBet - p.currentBet) : 0;
        uint256 totalCost = toCall + raiseAmount;
        require(p.chips >= totalCost, "Insufficient chips");

        if (toCall > 0) {
            p.chips -= toCall;
            playerChips[p.addr] -= toCall;
            p.currentBet += toCall;
            g.pot += toCall;
        }
        p.chips -= raiseAmount;
        playerChips[p.addr] -= raiseAmount;
        p.currentBet += raiseAmount;
        g.pot += raiseAmount;
        p.lastAction = PlayerAction.RAISE;

        g.currentBet = p.currentBet;
        for (uint256 i = 0; i < g.players.length; i++) {
            if (i != g.playerIndex[msg.sender] - 1) {
                if (g.players[i].isActive && !g.players[i].hasFolded && !g.players[i].isAllIn) {
                    g.players[i].lastAction = PlayerAction.NONE;
                }
            }
        }

        emit PlayerActed(gameId, msg.sender, PlayerAction.RAISE, totalCost);

        _advanceTurnOrShowdown(gameId);
    }

    function fold(uint256 gameId) 
        external
        onlyActiveGame(gameId)
        onlyPlayer(gameId)
    {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Not in betting phase");
        Player storage p = _getPlayerStorage(g, msg.sender);
        require(p.isActive && !p.hasFolded, "Player not active");

        p.hasFolded = true;
        p.isActive = false;
        p.lastAction = PlayerAction.FOLD;
        g.activeCount -= 1;

        if (p.card == 10 && p.chips >= 5) {
            p.chips -= 5;
            playerChips[p.addr] -= 5;
            g.pot += 5;
        }

        emit PlayerActed(gameId, msg.sender, PlayerAction.FOLD, 0);

        if (g.activeCount == 1) {
            _endRoundEarly(gameId);
            return;
        }

        _advanceTurnOrShowdown(gameId);
    }

    function _advanceTurnOrShowdown(uint256 gameId) internal {
        Game storage g = games[gameId];

        bool anyPending = false;
        for (uint256 i = 0; i < g.players.length; i++) {
            Player storage pp = g.players[i];
            if (pp.isActive && !pp.hasFolded && !pp.isAllIn && pp.lastAction == PlayerAction.NONE) {
                anyPending = true;
                break;
            }
        }

        if (anyPending) {
            uint256 tries = 0;
            uint256 idx = g.currentPlayerIdx;
            do {
                idx = (idx + 1) % g.players.length;
                tries++;
                if (tries > g.players.length) {
                    anyPending = false;
                    break;
                }
                Player storage candidate = g.players[idx];
                if (candidate.isActive && !candidate.hasFolded && !candidate.isAllIn && candidate.lastAction == PlayerAction.NONE) {
                    break;
                }
            } while (true);

            if (tries <= g.players.length) {
                g.currentPlayerIdx = idx;
                return;
            }
        }

        _showdown(gameId);
    }

    // ----------------------------------------
    // 5) 쇼다운 & 승자 판별 & 패 분배
    // ----------------------------------------

    function _showdown(uint256 gameId) internal {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Current phase is not betting");

        g.phase = GamePhase.SHOWDOWN;

        uint256 activeCnt = 0;
        for (uint256 i = 0; i < g.players.length; i++) {
            if (g.players[i].isActive && !g.players[i].hasFolded) {
                activeCnt++;
            }
        }

        address winner = _determineWinnerWithDraw(gameId);

        Player storage winP = _getPlayerStorage(g, winner);
        uint256 toReturn = 0;
        if (winP.isAllIn) {
            toReturn = winP.allInAmount;
            winP.chips += toReturn;
            playerChips[winP.addr] += toReturn;
            if (g.pot >= toReturn) {
                g.pot -= toReturn;
            } else {
                toReturn = g.pot;
                g.pot = 0;
            }
        }

        uint256 winAmt = g.pot;
        winP.chips += winAmt;
        playerChips[winP.addr] += winAmt;
        g.pot = 0;

        emit Showdown(gameId, winner, winAmt + toReturn);

        _nextRoundOrEnd(gameId, winner);
    }

    function _determineWinnerWithDraw(uint256 gameId) internal returns (address) {
        Game storage g = games[gameId];

        uint8 highest = 0;
        address[] memory tied = new address[](g.players.length);
        uint256 tieCnt = 0;

        for (uint256 i = 0; i < g.players.length; i++) {
            Player storage p = g.players[i];
            if (p.isActive && !p.hasFolded) {
                if (p.card > highest) {
                    highest = p.card;
                    tieCnt = 0;
                    tied[tieCnt++] = p.addr;
                } else if (p.card == highest) {
                    tied[tieCnt++] = p.addr;
                }
            }
        }

        if (tieCnt == 1) {
            return tied[0];
        }

        address[] memory tiedPlayers = new address[](tieCnt);
        for (uint256 i = 0; i < tieCnt; i++) {
            tiedPlayers[i] = tied[i];
        }

        return _resolveDraw(g, tiedPlayers);
    }

    function _resolveDraw(Game storage g, address[] memory tiedPlayers) internal returns (address) {
        uint8 newHighest = 0;
        address[] memory newTied = new address[](tiedPlayers.length);
        uint256 newTieCnt = 0;

        for (uint256 i = 0; i < tiedPlayers.length; i++) {
            address pa = tiedPlayers[i];
            uint8 card = _dealCard(g);
            Player storage p = _getPlayerStorage(g, pa);
            p.card = card;
            if (card > newHighest) {
                newHighest = card;
                newTieCnt = 0;
                newTied[newTieCnt++] = pa;
            } else if (card == newHighest) {
                newTied[newTieCnt++] = pa;
            }
        }

        if (newTieCnt == 1) {
            return newTied[0];
        }

        address[] memory nextTied = new address[](newTieCnt);
        for (uint256 i = 0; i < newTieCnt; i++) {
            nextTied[i] = newTied[i];
        }
        return _resolveDraw(g, nextTied);
    }

    function _endRoundEarly(uint256 gameId) internal {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Current phase is not betting");

        address winner;
        for (uint256 i = 0; i < g.players.length; i++) {
            Player storage p = g.players[i];
            if (p.isActive && !p.hasFolded) {
                winner = p.addr;
                break;
            }
        }
        Player storage winP = _getPlayerStorage(g, winner);
        winP.chips += g.pot;
        playerChips[winP.addr] += g.pot;
        uint256 winAmt = g.pot;
        g.pot = 0;

        emit Showdown(gameId, winner, winAmt);
        _nextRoundOrEnd(gameId, winner);
    }

    function _nextRoundOrEnd(uint256 gameId, address winner) internal {
        Game storage g = games[gameId];

        for (uint256 i = 0; i < g.players.length; i++) {
            Player storage p = g.players[i];
            p.card = 0;
            p.currentBet = 0;
            p.lastAction = PlayerAction.NONE;
            p.isAllIn = false;
            p.allInAmount = 0;
            p.hasFolded = false;
            p.isActive = true;
        }
        g.currentBet = 0;
        g.activeCount = g.players.length;
        g.pot = 0;

        uint256 totalChips = 0;
        for (uint256 i = 0; i < g.players.length; i++) {
            totalChips += g.players[i].chips;
        }
        if (g.players.length > 0) {
            uint256 target = 20 * g.players.length;
            for (uint256 i = 0; i < g.players.length; i++) {
                if (g.players[i].chips == target) {
                    g.phase = GamePhase.FINISHED;
                    g.isActive = false;
                    for (uint256 j = 0; j < g.players.length; j++) {
                        playerGameId[g.players[j].addr] = 0;
                    }
                    return;
                }
            }
        }

        // 다음 라운드 자동 시작: winner가 먼저
        g.phase = GamePhase.BETTING;
        g.currentBet = 0;
        _initializeAndShuffleDeck(g);

        // winner를 첫 순서로 설정
        uint256 winnerIdx = g.playerIndex[winner] - 1;
        g.currentPlayerIdx = winnerIdx;

        // 모든 플레이어 안티 지불
        g.pot = 0;
        for (uint256 i = 0; i < g.players.length; i++) {
            Player storage pl = g.players[i];
            if (pl.chips >= 1) {
                pl.chips -= 1;
                playerChips[pl.addr] -= 1;
                pl.currentBet = 1;
                g.pot += 1;
            } else if (pl.chips > 0) {
                // 남은 칩을 팟에 투입 후 탈락
                g.pot += pl.chips;
                playerChips[pl.addr] -= pl.chips;
                pl.chips = 0;
                pl.hasFolded = true;
                pl.isActive = false;
            } else {
                pl.hasFolded = true;
                pl.isActive = false;
            }
        }
        g.currentBet = 1;
        g.activeCount = 0;
        for (uint256 i = 0; i < g.players.length; i++) {
            if (g.players[i].isActive && !g.players[i].hasFolded) {
                g.activeCount++;
            }
        }

        // 카드 재배분
        for (uint256 i = 0; i < g.players.length; i++) {
            if (!g.players[i].hasFolded) {
                uint8 dealt = _dealCard(g);
                g.players[i].card = dealt;
                emit CardDealt(gameId, g.players[i].addr);
            }
        }
    }

    // ----------------------------------------
    // 6) 조회용 함수
    // ----------------------------------------

    function getGameInfo(uint256 gameId)
        external
        view
        returns (
            uint256 pot,
            uint256 currentBet,
            GamePhase phase,
            bool isActive,
            address ownerAddr,
            uint256 playerCount,
            uint256 activeCount
        )
    {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage g = games[gameId];
        return (
            g.pot,
            g.currentBet,
            g.phase,
            g.isActive,
            g.owner,
            g.players.length,
            g.activeCount
        );
    }

    // 모든 플레이어 칩 조회 함수
    function viewAllChips(uint256 gameId) external view onlyActiveGame(gameId) returns (address[] memory, uint256[] memory) {
        Game storage g = games[gameId];
        uint256 count = g.players.length;
        address[] memory addrs = new address[](count);
        uint256[] memory chips = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            addrs[i] = g.players[i].addr;
            chips[i] = g.players[i].chips;
        }
        return (addrs, chips);
    }

    function getPlayerInfo(uint256 gameId, address playerAddr)
        external
        view
        returns (
            uint256 chips,
            bool isActive,
            bool hasFolded_,
            uint256 currentBet,
            PlayerAction lastAction,
            bool cardVisible,
            uint8 visibleCard
        )
    {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage g = games[gameId];
        uint256 idx = g.playerIndex[playerAddr];
        require(idx > 0, "Player not in game");
        Player storage p = g.players[idx - 1];

        chips = p.chips;
        isActive = p.isActive;
        hasFolded_ = p.hasFolded;
        currentBet = p.currentBet;
        lastAction = p.lastAction;

        if (playerAddr == msg.sender) {
            cardVisible = false;
            visibleCard = 0;
        } else {
            cardVisible = true;
            visibleCard = p.card;
        }
    }

    function getCurrentPlayer(uint256 gameId) external view returns (address) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid game ID");
        Game storage g = games[gameId];
        if (g.phase == GamePhase.BETTING) {
            return g.players[g.currentPlayerIdx].addr;
        }
        return address(0);
    }

    // ----------------------------------------
    // 7) 상대방 카드 조회 함수
    // ----------------------------------------

    function viewOpponentsCards(uint256 gameId) external view onlyActiveGame(gameId) onlyPlayer(gameId) returns (address[] memory, uint8[] memory) {
        Game storage g = games[gameId];
        uint256 count = g.players.length - 1;
        address[] memory addrs = new address[](count);
        uint8[] memory cards = new uint8[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < g.players.length; i++) {
            if (g.players[i].addr != msg.sender) {
                addrs[idx] = g.players[i].addr;
                cards[idx] = g.players[i].card;
                idx++;
            }
        }
        return (addrs, cards);
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // ----------------------------------------
    // 8) 칩 환전 함수
    // ----------------------------------------

    function exchange(uint256 chipAmount) external {
        require(chipAmount > 0, "Amount must be greater than 0");
        require(playerChips[msg.sender] >= chipAmount, "Insufficient chips");
        require(playerGameId[msg.sender] == 0, "Cannot exchange while in game");

        // 1칩 당 반환 이더: 0.001 ETH / 20 = 0.00005 ETH
        uint256 ethAmount = (chipAmount * ENTRY_FEE) / 20;
        require(address(this).balance >= ethAmount, "Contract has insufficient balance");

        playerChips[msg.sender] -= chipAmount;
        payable(msg.sender).transfer(ethAmount);

        emit ChipsExchanged(msg.sender, chipAmount, ethAmount);
    }

    // ----------------------------------------
    // 9) 내부 헬퍼: Player storage 반환
    // ----------------------------------------

    function _getPlayerStorage(Game storage g, address playerAddr) internal view returns (Player storage) {
        uint256 idx = g.playerIndex[playerAddr];
        require(idx > 0, "Player not found");
        return g.players[idx - 1];
    }
}
