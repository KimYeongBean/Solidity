// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/*
  Indian Poker 3.4 -> 3.5 (MinContribution 올인 반환 기능 추가, 가스 최적화 유지)
  • 올인 시 최소 기여액 기준으로 초과 베팅액 반환
  • 기존 기능 및 구조체, 배열 고정 등 가스 최적화 유지
*/

contract IndianPoker_3_2 {
    enum CardValue { UNASSIGNED, ONE, TWO, THREE, FOUR, FIVE, SIX, SEVEN, EIGHT, NINE, TEN }
    enum GamePhase  { WAITING, BETTING, SHOWDOWN, FINISHED }
    enum PlayerAction { NONE, BET, CALL, RAISE, FOLD, ALL_IN }

    struct Player {
        address       addr;
        uint8         chips;
        uint8         card;
        bool          hasFolded;
        uint8         currentBet;
        PlayerAction  lastAction;
        bool          isAllIn;
        uint8         allInAmount;
    }

    struct Game {
        address       owner;
        uint8         pot;
        uint8         currentBet;
        uint8         currentPlayerIdx;
        GamePhase     phase;
        uint8         activeCount;
        uint8         deckIndex;
        uint8[20]     deck;
        Player[6]     players;
        uint8         playerCount;
        uint8         minBet;
    }

    uint256 public gameCounter;
    mapping(uint256 => Game) private games;
    mapping(address => uint8)  public playerChips;
    mapping(address => uint256) public playerGameId;

    uint8   constant ENTRY_FEE_CHIPS = 20;
    uint256 constant ENTRY_FEE       = 0.001 ether;
    uint8   constant MAX_PLAYERS     = 6;
    uint8   constant MIN_PLAYERS     = 2;

    // -----------------------
    // Events
    // -----------------------
    event GameCreated(uint256 gameId);
    event PlayerJoined(uint256 gameId, address player);
    event GameStarted(uint256 gameId);
    event PlayerActed(uint256 gameId, address player, PlayerAction action, uint8 amount);
    event CardDealt(uint256 gameId, address player);
    event Showdown(uint256 gameId, address winner, uint8 winAmount);
    event TieBreakerCard(address indexed player, uint8 card);

    // -----------------------
    // Modifiers
    // -----------------------
    modifier onlyOwner(uint256 gameId) {
        require(gameId <= gameCounter && games[gameId].owner == msg.sender, "Not owner");
        _;
    }
    modifier onlyActive(uint256 gameId) {
        require(games[gameId].phase != GamePhase.FINISHED, "Game over");
        _;
    }
    modifier onlyInGame(uint256 gameId) {
        require(playerGameId[msg.sender] == gameId, "Not in game");
        _;
    }
    modifier inPhase(uint256 gameId, GamePhase p) {
        require(games[gameId].phase == p, "Wrong phase");
        _;
    }

    // -----------------------
    // 1) createGame / joinGame / startGame
    // -----------------------

    function createGame() external returns (uint256) {
        require(playerGameId[msg.sender] == 0, "Already playing");
        gameCounter++;
        Game storage g = games[gameCounter];
        g.owner = msg.sender;
        g.phase = GamePhase.WAITING;
        g.currentBet = 0;
        g.pot = 0;
        g.activeCount = 0;
        g.currentPlayerIdx = 0;
        g.deckIndex = 0;
        g.minBet = 1;
        emit GameCreated(gameCounter);
        return gameCounter;
    }

    function joinGame(uint256 gameId) external payable onlyActive(gameId) {
        Game storage g = games[gameId];
        require(
            msg.value == ENTRY_FEE &&
            g.phase == GamePhase.WAITING &&   
            g.playerCount < MAX_PLAYERS &&
            playerGameId[msg.sender] == 0,
            "Send 0.001 ETH/Already started/Game full/Already in game"
        );
        uint8 idx = g.playerCount;
        g.players[idx] = Player({
            addr:         msg.sender,
            chips:        ENTRY_FEE_CHIPS,
            card:         0,
            hasFolded:    false,
            currentBet:   0,
            lastAction:   PlayerAction.NONE,
            isAllIn:      false,
            allInAmount:  0
        });
        g.playerCount++;
        g.activeCount = g.playerCount;
        playerGameId[msg.sender] = gameId;
        playerChips[msg.sender] += ENTRY_FEE_CHIPS;
        emit PlayerJoined(gameId, msg.sender);
    }

    function startGame(uint256 gameId)
        external
        onlyOwner(gameId)
        inPhase(gameId, GamePhase.WAITING)
    {
        Game storage g = games[gameId];
        uint8 n = g.playerCount;
        require(n >= MIN_PLAYERS, "Not enough");

        // Round 1 chip ante (1 chip each)
        for (uint8 i = 0; i < n; i++) {
            Player storage pl = g.players[i];
            require(pl.chips >= 1, "No chips");
            pl.chips--;
            playerChips[pl.addr]--;
            g.pot++;
            pl.currentBet = 1;
        }
        g.currentBet      = 1;
        g.phase           = GamePhase.BETTING;
        g.currentPlayerIdx = 0;

        _initDeck(g);
        for (uint8 i = 0; i < n; i++) {
            uint8 c = _dealCard(g);
            g.players[i].card = c;
            emit CardDealt(gameId, g.players[i].addr);
        }
        emit GameStarted(gameId);
    }

    // -----------------------
    // 2) Betting / Call / Raise / Fold
    // -----------------------

    function bet(uint256 gameId, uint8 amount)
        external
        onlyInGame(gameId)
        onlyActive(gameId)
    {
        Game storage g = games[gameId];
        uint8 idx = g.currentPlayerIdx;
        Player storage p = g.players[idx];
        require(
            g.phase == GamePhase.BETTING && 
            p.addr == msg.sender &&
            !p.hasFolded &&
            !p.isAllIn,
            "Wrong phase/Not your turn"
        );

        uint8 toCall = (g.currentBet > p.currentBet) ? (g.currentBet - p.currentBet) : 0;
        uint8 total  = toCall + amount;
        require(amount >= g.minBet && total <= p.chips, "Invalid bet");

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
            _resetActions(g, idx);
        }
        emit PlayerActed(gameId, msg.sender, PlayerAction.BET, total);
        _advanceNextPlayer(gameId);
    }

    function call(uint256 gameId)
        external
        onlyInGame(gameId)
        onlyActive(gameId)
    {
        Game storage g = games[gameId];
        uint8 idx = g.currentPlayerIdx;
        Player storage p = g.players[idx];
        require(
            g.phase == GamePhase.BETTING &&
            p.addr == msg.sender &&
            !p.hasFolded &&
            !p.isAllIn,
            "Wrong phase/Not your turn"
        );

        uint8 toCall = (g.currentBet > p.currentBet) ? (g.currentBet - p.currentBet) : 0;
        require(toCall > 0, "Nothing to call");

        // 올인 혹은 일반 콜
        if (p.chips <= toCall) {
            uint8 allInAmt = p.chips;
            p.chips = 0;
            playerChips[p.addr] -= allInAmt;
            p.isAllIn = true;
            p.allInAmount = p.currentBet + allInAmt;
            p.currentBet += allInAmt;
            g.pot += allInAmt;
            p.lastAction = PlayerAction.ALL_IN;
            emit PlayerActed(gameId, msg.sender, PlayerAction.ALL_IN, allInAmt);
        } else {
            p.chips -= toCall;
            playerChips[p.addr] -= toCall;
            p.currentBet += toCall;
            g.pot += toCall;
            p.lastAction = PlayerAction.CALL;
            emit PlayerActed(gameId, msg.sender, PlayerAction.CALL, toCall);
        }

        if (p.currentBet > g.currentBet) {
            g.currentBet = p.currentBet;
            _resetActions(g, idx);
        }
        _advanceNextPlayer(gameId);
    }

    function raise(uint256 gameId, uint8 raiseAmt)
        external
        onlyInGame(gameId)
        onlyActive(gameId)
    {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Wrong phase");

        uint8 idx = g.currentPlayerIdx;
        Player storage p = g.players[idx];
        require(
            p.addr == msg.sender &&
            !p.hasFolded &&
            !p.isAllIn,
            "Not your turn"
        );

        uint8 toCall = (g.currentBet > p.currentBet) ? (g.currentBet - p.currentBet) : 0;
        uint8 total  = toCall + raiseAmt;
        require(raiseAmt > 0 && total <= p.chips, "Invalid raise");

        if (toCall > 0) {
            p.chips -= toCall;
            playerChips[p.addr] -= toCall;
            p.currentBet += toCall;
            g.pot += toCall;
        }
        p.chips -= raiseAmt;
        playerChips[p.addr] -= raiseAmt;
        p.currentBet += raiseAmt;
        g.pot += raiseAmt;

        p.lastAction    = PlayerAction.RAISE;
        g.currentBet    = p.currentBet;
        _resetActions(g, idx);
        emit PlayerActed(gameId, msg.sender, PlayerAction.RAISE, total);
        _advanceNextPlayer(gameId);
    }

    function fold(uint256 gameId)
        external
        onlyInGame(gameId)
        onlyActive(gameId)
    {
        Game storage g = games[gameId];
        require(g.phase == GamePhase.BETTING, "Wrong phase");

        uint8 idx = g.currentPlayerIdx;
        Player storage p = g.players[idx];
        require(
            p.addr == msg.sender &&
            !p.hasFolded &&
            !p.isAllIn,
            "Not your turn"
        );

        p.hasFolded   = true;
        p.lastAction  = PlayerAction.FOLD;
        g.activeCount--;

        if (p.card == 10 && p.chips >= 5) {
            p.chips -= 5;
            playerChips[p.addr] -= 5;
            g.pot += 5;
        }
        emit PlayerActed(gameId, msg.sender, PlayerAction.FOLD, 0);
        if (g.activeCount == 1) { _endRoundEarly(gameId); return; }
        _advanceNextPlayer(gameId);
    }

    // -----------------------
    // 3) Turn Advancement / Showdown / MinContribution 반환 로직
    // -----------------------

    function _advanceNextPlayer(uint256 gameId) internal {
        Game storage g = games[gameId];
        uint8 n = g.playerCount;
        bool pending;
        for (uint8 i = 0; i < n; i++) {
            Player storage pp = g.players[i];
            if (!pp.hasFolded && !pp.isAllIn && pp.lastAction == PlayerAction.NONE) { pending = true; break; }
        }
        if (pending) {
            uint8 tries;
            uint8 idx = g.currentPlayerIdx;
            do {
                idx = (idx + 1) % n;
                tries++;
                if (tries > n) { pending = false; break; }
                Player storage c = g.players[idx];
                if (!c.hasFolded && !c.isAllIn && c.lastAction == PlayerAction.NONE) break;
            } while (true);
            if (tries <= n) { g.currentPlayerIdx = idx; } else { _showdown(gameId); }
        } else { _showdown(gameId); }
    }

    function _showdown(uint256 gameId) internal {
        Game storage g = games[gameId];
        g.phase = GamePhase.SHOWDOWN;

        uint8 n = g.playerCount;
        address winner;
        uint8  highest;
        uint8  tieCount;
        address[6] memory tied;

        // 1) 최고 카드 찾기
        for (uint8 i = 0; i < n; i++) {
            Player storage p = g.players[i];
            if (!p.hasFolded) {
                if (p.card > highest) { highest = p.card; tieCount = 0; tied[tieCount++] = p.addr; }
                else if (p.card == highest) { tied[tieCount++] = p.addr; }
            }
        }
        if (tieCount == 1) { winner = tied[0]; }
        else {
            address[] memory t2 = new address[](tieCount);
            for (uint8 i = 0; i < tieCount; i++) t2[i] = tied[i];
            winner = _resolveDraw(g, t2);
        }

        // 2) 쇼다운 시 MinContribution 계산
        //   각 플레이어의 currentBet 중 최소값을 찾음
        uint8 minContribution = type(uint8).max;
        for (uint8 i = 0; i < n; i++) {
            Player storage p = g.players[i];
            if (!p.hasFolded) {
                if (p.currentBet < minContribution) {
                    minContribution = p.currentBet;
                }
            }
        }
        // 3) 초과 베팅액 반환
        for (uint8 i = 0; i < n; i++) {
            Player storage p = g.players[i];
            if (!p.hasFolded) {
                uint8 excess = p.currentBet - minContribution;
                if (excess > 0) {
                    p.chips += excess;
                    playerChips[p.addr] += excess;
                    g.pot -= excess;
                }
                p.currentBet = minContribution;
            }
        }
        // 팟에는 이제 minContribution * 참여인원만 남음

        // 4) 승자에게 팟 전부 지급
        Player storage winP = _getPlayerIndex(g, winner);
        uint8 winAmt = g.pot;
        winP.chips += winAmt;
        playerChips[winP.addr] += winAmt;
        g.pot = 0;

        emit Showdown(gameId, winner, winAmt);
        _nextRoundOrEnd(gameId, winner);
    }

    function _resolveDraw(Game storage g, address[] memory tiedPlayers)
        internal
        returns (address)
    {
        uint8 newHighest;
        uint8 newTieCount;
        address[] memory newTied = new address[](tiedPlayers.length);
        for (uint8 i = 0; i < tiedPlayers.length; i++) {
            address pa = tiedPlayers[i];
            uint8 c = _dealCard(g);
            Player storage p = _getPlayerIndex(g, pa);
            p.card = c;
            emit TieBreakerCard(pa, c); // 이벤트 추가
            
            if (c > newHighest) { newHighest = c; newTieCount = 0; newTied[newTieCount++] = pa; }
            else if (c == newHighest) { newTied[newTieCount++] = pa; }
        }
        if (newTieCount == 1) { return newTied[0]; }
        address[] memory nextTied = new address[](newTieCount);
        for (uint8 i = 0; i < newTieCount; i++) { nextTied[i] = newTied[i]; }
        return _resolveDraw(g, nextTied);
    }

    function _endRoundEarly(uint256 gameId) internal {
        Game storage g = games[gameId];
        address winner;
        uint8 n = g.playerCount;
        for (uint8 i = 0; i < n; i++) {
            Player storage p = g.players[i]; if (!p.hasFolded) { winner = p.addr; break; }
        }
        Player storage winP = _getPlayerIndex(g, winner);
        winP.chips += g.pot;
        playerChips[winP.addr] += g.pot;
        uint8 winAmt = g.pot;
        g.pot = 0;
        emit Showdown(gameId, winner, winAmt);
        _nextRoundOrEnd(gameId, winner);
    }

    function _nextRoundOrEnd(uint256 gameId, address winner) internal {
        Game storage g = games[gameId];
        uint8 n = g.playerCount;
        // 플레이어 상태 리셋
        for (uint8 i = 0; i < n; i++) {
            Player storage p = g.players[i];
            p.card = 0;
            p.currentBet = 0;
            p.lastAction = PlayerAction.NONE;
            p.isAllIn = false;
            p.allInAmount = 0;
            p.hasFolded = false;
        }
        g.currentBet = 0;
        g.activeCount = n;
        g.pot = 0;
        // 총 칩 검사 및 게임 종료
        uint16 totalChips;
        for (uint8 i = 0; i < n; i++) { totalChips += g.players[i].chips; }
        uint8 target = ENTRY_FEE_CHIPS * n;
        for (uint8 i = 0; i < n; i++) {
            if (g.players[i].chips == target) {
                address payable payWinner = payable(winner);
                uint256 balance = address(this).balance;
                if (balance > 0) { payWinner.transfer(balance); }
                g.phase = GamePhase.FINISHED;
                // 게임ID 초기화
                for (uint8 j = 0; j < n; j++) {
                    playerGameId[g.players[j].addr] = 0;
                }
                return;
            }
        }
        // 다음 라운드 시작 (winner 우선)
        g.phase = GamePhase.BETTING;
        g.currentBet = 0;
        _initDeck(g);
        uint8 winnerIdx = _findPlayerIndex(g, winner);
        g.currentPlayerIdx = winnerIdx;
        g.pot = 0;
        g.activeCount = 0;
        for (uint8 i = 0; i < n; i++) {
            Player storage pl = g.players[i];
            if (pl.chips >= 1) {
                pl.chips--;
                playerChips[pl.addr]--;
                pl.currentBet = 1;
                g.pot++;
            } else if (pl.chips > 0) {
                g.pot += pl.chips;
                playerChips[pl.addr] -= pl.chips;
                pl.chips = 0;
                pl.hasFolded = true;
            } else { pl.hasFolded = true; }
        }
        g.currentBet = 1;
        for (uint8 i = 0; i < n; i++) { if (!g.players[i].hasFolded) g.activeCount++; }
        for (uint8 i = 0; i < n; i++) {
            if (!g.players[i].hasFolded) {
                uint8 d = _dealCard(g);
                g.players[i].card = d;
                emit CardDealt(gameId, g.players[i].addr);
            }
        }
    }

    // -----------------------
    // 4) 조회용 함수
    // -----------------------

    function getGameInfo(uint256 gameId)
        external
        view
        returns (
            uint8      pot,
            uint8      currentBet,
            GamePhase  phase,
            address    owner,
            uint8      playerCount,
            uint8      activeCount
        )
    {
        require(gameId > 0 && gameId <= gameCounter, "Invalid");
        Game storage g = games[gameId];
        return (
            g.pot,
            g.currentBet,
            g.phase,
            g.owner,
            g.playerCount,
            g.activeCount
        );
    }

    function viewAllChips(uint256 gameId)
        external
        view
        onlyActive(gameId)
        returns (address[] memory, uint8[] memory)
    {
        Game storage g = games[gameId];
        uint8 n = g.playerCount;
        address[] memory addrs = new address[](n);
        uint8[]   memory chips = new uint8[](n);
        for (uint8 i = 0; i < n; i++) {
            addrs[i] = g.players[i].addr;
            chips[i] = g.players[i].chips;
        }
        return (addrs, chips);
    }

    function getCurrentPlayer(uint256 gameId) external view returns (address) {
        require(gameId > 0 && gameId <= gameCounter, "Invalid");
        Game storage g = games[gameId];
        if (g.phase == GamePhase.BETTING) {
            return g.players[g.currentPlayerIdx].addr;
        }
        return address(0);
    }

    function viewOpponentsCards(uint256 gameId)
        external
        view
        onlyActive(gameId)
        onlyInGame(gameId)
        returns (address[] memory, uint8[] memory)
    {
        Game storage g = games[gameId];
        uint8 n = g.playerCount - 1;
        address[] memory addrs = new address[](n);
        uint8[]   memory cards = new uint8[](n);
        uint8 idx;
        for (uint8 i = 0; i < g.playerCount; i++) {
            if (g.players[i].addr != msg.sender) {
                addrs[idx] = g.players[i].addr;
                cards[idx] = g.players[i].card;
                idx++;
            }
        }
        return (addrs, cards);
    }

    // -----------------------
    // 5) 내부 헬퍼
    // -----------------------

    function _getPlayerIndex(Game storage g, address addr) internal view returns (Player storage) {
        for (uint8 i = 0; i < g.playerCount; i++) {
            if (g.players[i].addr == addr) {
                return g.players[i];
            }
        }
        revert("No such player");
    }

    function _findPlayerIndex(Game storage g, address addr) internal view returns (uint8) {
        for (uint8 i = 0; i < g.playerCount; i++) {
            if (g.players[i].addr == addr) return i;
        }
        revert("No such player");
    }

    function _resetActions(Game storage g, uint8 actorIdx) internal {
        for (uint8 i = 0; i < g.playerCount; i++) {
            if (i != actorIdx) {
                Player storage pl = g.players[i];
                if (!pl.hasFolded && !pl.isAllIn) pl.lastAction = PlayerAction.NONE;
            }
        }
    }

    function _initDeck(Game storage g) internal {
        uint8 idx;
        for (uint8 v = 1; v <= 10; v++) {
            g.deck[idx++] = v;
            g.deck[idx++] = v;
        }
        for (uint8 i = 19; i > 0; i--) {
            uint8 j = uint8(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, i))) % (i + 1));
            (g.deck[i], g.deck[j]) = (g.deck[j], g.deck[i]);
        }
        g.deckIndex = 0;
    }

    function _dealCard(Game storage g) internal returns (uint8) {
        if (g.deckIndex >= 20) { _initDeck(g); }
        return g.deck[g.deckIndex++];
    }
}