// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

contract IndianPoker_final {
    enum GamePhase  { WAITING, BETTING, SHOWDOWN, FINISHED, ALL_IN } // 게임의 상태들
    enum PlayerAction { NONE, CALL, RAISE, FOLD, ALL_IN } // 플레이어의 행동 종류

    // 플레이어 구조체
    struct Player {
        address     addr;         // 플레이어 지갑 주소
        uint8       chips;        // 보유 칩 수
        uint8       card;         // 배정 받은 카드
        bool        hasFolded;    // 포기 여부
        uint8       currentBet;   // 현재 배팅 칩 수
        PlayerAction lastAction;  // 마지막 액션
        bool        isAllIn;      // 올인 상태 여부
        uint8       allInAmount;  // 올인 시 베팅한 총액
    }

    // 게임 정보 구조체
    struct Game {
        uint8       pot;              // 배팅 칩을 보관하는 팟
        uint8       currentBet;       // 현재 라운드의 최고 배팅 칩
        uint8       currentPlayerIdx; // 현재 플레이어 인덱스
        GamePhase   phase;            // 현재 게임 상태
        uint8       activeCount;      // 폴드하지 않은 플레이어 수
        uint8       deckIndex;        // 덱의 다음 카드 인덱스
        uint8[20]   deck;             // 카드 20장
        Player[6]   players;          // 최대 6명 플레이어 배열
        uint8       playerCount;      // 현재 게임에 참여한 플레이어 수
    }

    address owner; // 컨트랙트 배포자(오너) 주소
    uint8 public gameCounter; // 생성된 총 게임 수
    mapping(uint8 => Game) private games; // 게임 아이디와 게임 구조체 매핑
    mapping(address => uint8) playerGameId; // 플레이어 주소와 참여한 게임 아이디 매핑

    uint8   constant ENTRY_FEE_CHIPS = 20;      // 1인당 받는 칩 수(20)
    uint64  constant ENTRY_FEE       = 0.001 ether; // 참가 금액(0.001 이더)
    uint8   constant MAX_PLAYERS     = 6;         // 최대 참가자 수(6)
    uint8   constant MIN_PLAYERS     = 2;         // 최소 참가자 수(2)
    uint8   constant MIN_BET         = 1;         // 최소 배팅 금액(1)

    // 이벤트
    event GameCreated(uint8 gameId); // 게임 생성 시 게임아이디 보여줌
    event PlayerJoined(uint8 gameId, address player); // 플레이어 참가 시 게임아이디와 플레이어 주소 보여줌
    event GameStarted(uint8 gameId); // 게임 시작 시 게임 아이디 보여줌
    event PlayerActed(uint8 gameId, address player, PlayerAction action, uint8 amount); // 플레이어 액션 시 정보 보여줌
    event CardDealt(uint8 gameId, address player); // 카드 분배 시 정보 보여줌
    event Showdown(uint8 gameId, address winner, uint8 winAmount); // 라운드 종료 시 승자와 가져가는 칩 수 보여줌
    event TieBreakerCard(address indexed player, uint8 card); // 무승부 재결정 시 뽑은 카드 정보 보여줌

    // 모디파이어
    modifier onlyOwner() { // 오너만 호출 가능
        require(owner == msg.sender, "Not owner"); // 오너가 아니면 오류 메세지
        _; // 조건 통과 시 함수 실행
    }
    modifier onlyActive(uint8 gameId) { // 게임이 종료되지 않았는지 검사
        require(games[gameId].phase != GamePhase.FINISHED, "Game over"); // 게임이 끝났으면 오류 메세지
        _;
    }
    modifier onlyInGame(uint8 gameId) { // 게임에 참가 중인 플레이어인지 검사
        require(playerGameId[msg.sender] == gameId, "Not in game"); // 해당 게임 참가자가 아니면 오류 메세지
        _;
    }
    modifier inPhase(uint8 gameId, GamePhase p) { // 게임이 지정된 상태인지 검사
        require(games[gameId].phase == p, "Wrong phase"); // 지정된 상태가 아니면 오류 메세지
        _;
    }

    // 게임 생성 함수
    function createGame() external returns (uint8) {
        require(playerGameId[msg.sender] == 0, "Already playing"); // 이미 다른 게임에 참가 중인지 검사
        gameCounter++; // 전체 게임 카운터 +1
        Game storage g = games[gameCounter]; // 새 게임 객체 g 생성
        owner = msg.sender; // 오너를 게임 생성자로 지정
        g.phase = GamePhase.WAITING; // 게임 상태를 '대기'로 변경
        g.currentBet = 0; // 게임 변수들 초기화
        g.pot = 0; // 팟 초기화
        g.activeCount = 0; // 활성 플레이어 수 초기화
        g.currentPlayerIdx = 0; // 현재 플레이어 인덱스 초기화
        g.deckIndex = 0; // 덱 인덱스 초기화
        emit GameCreated(gameCounter); // 게임 생성 이벤트 호출
        return gameCounter; // 생성된 게임 아이디 리턴
    }

    // 게임 참가 함수
    function joinGame(uint8 gameId) external payable onlyActive(gameId) {
        Game storage g = games[gameId]; // 함수 내에서 사용할 게임 객체 g 생성
        require( // 게임 입장 조건 검사
            msg.value == ENTRY_FEE && // 보낸 이더가 참가비와 같은지 확인
            g.phase == GamePhase.WAITING && // 게임 상태가 '대기'인지 확인
            g.playerCount < MAX_PLAYERS && // 최대 참가자 수보다 적은지 확인
            playerGameId[msg.sender] == 0, // 다른 게임에 참가 중이 아닌지 확인
            "Send 0.001 ETH/Already started/Game full/Already in game" // 오류 메세지
        );
        uint8 idx = g.playerCount; // 새 플레이어의 인덱스 설정
        g.players[idx] = Player({ // 게임 내 플레이어 배열에 새 플레이어 정보 생성
            addr:         msg.sender, // 플레이어 주소
            chips:        ENTRY_FEE_CHIPS, // 기본 칩 지급(20)
            card:         0, // 카드는 아직 없음(0)
            hasFolded:    false, // 포기 상태 아님
            currentBet:   0, // 현재 배팅액 0
            lastAction:   PlayerAction.NONE, // 마지막 행동 없음
            isAllIn:      false, // 올인 상태 아님
            allInAmount:  0 // 올인 금액 0
        });
        g.playerCount++; // 현재 게임의 플레이어 카운트 +1
        g.activeCount = g.playerCount; // 활성 플레이어 수를 현재 플레이어 수와 동기화
        playerGameId[msg.sender] = gameId; // 플레이어의 참가 게임 아이디 기록
        g.players[idx].chips = ENTRY_FEE_CHIPS; // 플레이어 칩은 20개로 고정 (중복 확인)
        emit PlayerJoined(gameId, msg.sender); // 플레이어 참가 이벤트 호출
    }

    // 게임 시작 함수
    function startGame(uint8 gameId) external onlyOwner inPhase(gameId, GamePhase.WAITING) {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        uint8 n = g.playerCount; // 전체 플레이어 수
        require(n >= MIN_PLAYERS, "Not enough"); // 최소 플레이어 수를 충족했는지 검사

        // 라운드 시작 시 기본 칩 1개씩 배팅
        for (uint8 i = 0; i < n; i++) {
            Player storage pl = g.players[i]; // 각 플레이어 객체 불러오기
            require(pl.chips >= 1, "No chips"); // 기본칩을 낼 칩이 있는지 확인
            pl.chips--; // 플레이어 칩 1개 차감
            g.pot++; // 게임 팟에 칩 1개 추가
            pl.currentBet = 1; // 현재 라운드 배팅액을 1로 설정
        }
        g.currentBet = 1; // 현재 게임의 최고 배팅금액을 1로 설정
        g.phase = GamePhase.BETTING; // 게임 상태를 '배팅중'으로 변경
        g.currentPlayerIdx = 0; // 현재 플레이어를 0번 플레이어로 설정

        _initDeck(g); // 덱 초기화 및 셔플 함수 호출
        for (uint8 i = 0; i < n; i++) { // 모든 플레이어에게 카드 분배
            uint8 c = _dealCard(g); // 덱에서 카드 한 장 뽑기
            g.players[i].card = c; // 플레이어에게 카드 전달
            emit CardDealt(gameId, g.players[i].addr); // 카드 분배 이벤트 호출
        }
        emit GameStarted(gameId); // 게임 시작 이벤트 호출
    }

    // 콜 함수: 이전 플레이어의 배팅 금액만큼 배팅
    function call(uint8 gameId) external onlyInGame(gameId) onlyActive(gameId) {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        uint8 idx = g.currentPlayerIdx; // 현재 플레이어 인덱스 불러오기
        Player storage p = g.players[idx]; // 현재 플레이어 객체 생성
        require( // 콜을 할 수 있는 상태인지 확인
            g.phase == GamePhase.BETTING && // 게임 상태가 '배팅중'인지
            p.addr == msg.sender && // 현재 턴의 플레이어인지
            !p.hasFolded && // 게임을 포기한 상태가 아닌지
            !p.isAllIn, // 올인 상태가 아닌지
            "Wrong phase/Not your turn" // 오류 메세지
        );

        uint8 toCall = (g.currentBet > p.currentBet) ? (g.currentBet - p.currentBet) : 0; // 앞사람 배팅액에 맞춰 내야 할 칩(콜 금액) 계산
        require(toCall > 0, "Nothing to call"); // 콜 할 금액이 있는지 확인

        // 올인 혹은 일반 콜 처리
        if (p.chips <= toCall) { // 보유한 칩이 콜 금액보다 적거나 같으면 올인
            uint8 allInAmt = p.chips; // 올인 금액은 현재 보유한 칩 전부
            p.chips = 0; // 보유 칩을 0으로 설정
            p.isAllIn = true; // 플레이어의 올인 상태를 true로 변경
            p.allInAmount = p.currentBet + allInAmt; // 올인 시 총 베팅액 기록
            p.currentBet += allInAmt; // 누적 배팅액에 올인 금액 추가
            g.pot += allInAmt; // 팟에 올인 금액 추가
            p.lastAction = PlayerAction.ALL_IN; // 마지막 행동을 '올인'으로 변경
            g.phase = GamePhase.ALL_IN; // 게임 상태를 '올인'으로 변경 (참고용)
            emit PlayerActed(gameId, msg.sender, PlayerAction.ALL_IN, allInAmt); // 올인 액션 이벤트 호출
        } else { // 보유 칩이 충분하면 일반 콜
            p.chips -= toCall; // 보유 칩에서 콜 금액 차감
            p.currentBet += toCall; // 누적 배팅액에 콜 금액 추가
            g.pot += toCall; // 팟에 콜 금액 추가
            p.lastAction = PlayerAction.CALL; // 마지막 행동을 '콜'로 변경
            emit PlayerActed(gameId, msg.sender, PlayerAction.CALL, toCall); // 콜 액션 이벤트 호출
        }

        if (p.currentBet > g.currentBet) { // (올인 금액이 더 적을 수 있으므로) 내 배팅액이 더 높다면
            g.currentBet = p.currentBet; // 게임의 최고 배팅액을 내 배팅액으로 갱신
            _resetActions(g, idx); // 다른 플레이어들의 행동 상태 리셋
        }
        _advanceNextPlayer(gameId); // 다음 플레이어로 턴을 넘기는 함수 실행
    }

    // 레이즈 함수: 배팅 금액을 올림
    function raise(uint8 gameId, uint8 raiseAmt) external onlyInGame(gameId) onlyActive(gameId) {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        require(g.phase == GamePhase.BETTING && g.phase != GamePhase.ALL_IN, "Wrong phase"); // 게임 상태 확인

        uint8 idx = g.currentPlayerIdx; // 현재 플레이어 인덱스 불러오기
        Player storage p = g.players[idx]; // 현재 플레이어 객체 생성
        require( // 레이즈를 할 수 있는 상태인지 확인
            p.addr == msg.sender && // 현재 턴의 플레이어인지
            !p.hasFolded && // 게임을 포기한 상태가 아닌지
            !p.isAllIn, // 올인 상태가 아닌지
            "Not your turn" // 오류 메세지
        );

        uint8 toCall = (g.currentBet > p.currentBet) ? (g.currentBet - p.currentBet) : 0; // 콜 금액 계산
        uint8 total = toCall + raiseAmt; // 콜 금액 + 추가 레이즈 금액
        require(raiseAmt > 0 && total <= p.chips, "Invalid raise"); // 레이즈 금액이 0보다 크고, 총액이 보유 칩보다 적은지 확인

        if (toCall > 0) { // 내야 할 콜 금액이 있다면
            p.chips -= toCall; // 보유 칩에서 콜 금액만큼 차감
            p.currentBet += toCall; // 누적 배팅액에 콜 금액 추가
            g.pot += toCall; // 팟에 콜 금액 추가
        }
        p.chips -= raiseAmt; // 보유 칩에서 레이즈 금액만큼 차감
        p.currentBet += raiseAmt; // 누적 배팅액에 레이즈 금액 추가
        g.pot += raiseAmt; // 팟에 레이즈 금액 추가

        p.lastAction = PlayerAction.RAISE; // 마지막 행동을 '레이즈'로 기록
        g.currentBet = p.currentBet; // 게임의 최고 배팅액을 내 배팅액으로 갱신
        _resetActions(g, idx); // 나를 제외한 다른 플레이어들의 행동 상태를 리셋
        emit PlayerActed(gameId, msg.sender, PlayerAction.RAISE, total); // 레이즈 액션 이벤트 호출
        _advanceNextPlayer(gameId); // 다음 플레이어로 턴을 넘기는 함수 실행
    }

    // 폴드 함수: 현재 라운드의 게임을 포기
    function fold(uint8 gameId) external onlyInGame(gameId) onlyActive(gameId) {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        require(g.phase == GamePhase.BETTING, "Wrong phase"); // 게임 상태가 '배팅중'인지 확인

        uint8 idx = g.currentPlayerIdx; // 현재 플레이어 인덱스 불러오기
        Player storage p = g.players[idx]; // 현재 플레이어 객체 생성
        require( // 폴드를 할 수 있는 상태인지 확인
            p.addr == msg.sender && // 현재 턴의 플레이어인지
            !p.hasFolded && // 이미 포기한 상태가 아닌지
            !p.isAllIn, // 올인 상태가 아닌지
            "Not your turn" // 오류 메세지
        );

        p.hasFolded = true; // 플레이어의 포기 상태를 true로 변경
        p.lastAction = PlayerAction.FOLD; // 마지막 행동을 '폴드'로 기록
        g.activeCount--; // 활성 플레이어 수 1 감소

        // 만약 10 카드를 들고 포기했다면 패널티로 칩 5개를 냄
        if (p.card == 10 && p.chips >= 5) {
            p.chips -= 5; // 칩 5개 감소
            g.pot += 5; // 팟에 5개 추가
        }
        // 보유한 칩이 5개 보다 적다면 전부 냄
        else if(p.card == 10 && p.chips < 5){ 
            g.pot += p.chips;   // pot에 칩 전부 추가
            p.chips = 0;        // 남은 칩 0
        }
        emit PlayerActed(gameId, msg.sender, PlayerAction.FOLD, 0); // 폴드 액션 이벤트 호출
        if (g.activeCount == 1) { _endRoundEarly(gameId); return; } // 남은 플레이어가 1명이면 즉시 라운드 종료
        _advanceNextPlayer(gameId); // 다음 플레이어로 턴을 넘기는 함수 실행
    }

    // 다음 플레이어를 찾는 내부 함수
    function _advanceNextPlayer(uint8 gameId) internal {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        uint8 n = g.playerCount; // 전체 플레이어 수
        bool pending; // 행동해야 할 플레이어가 남았는지 여부
        for (uint8 i = 0; i < n; i++) { // 모든 플레이어를 순회
            Player storage pp = g.players[i]; // 각 플레이어 객체 불러오기
            if (!pp.hasFolded && !pp.isAllIn && pp.lastAction == PlayerAction.NONE) { pending = true; break; } // 아직 행동 안 한 플레이어가 있으면 pending을 true로 바꾸고 중단
        }
        if (pending) { // 행동할 플레이어가 남아있다면
            uint8 tries; // 무한루프 방지용 카운터
            uint8 idx = g.currentPlayerIdx; // 현재 플레이어 인덱스
            do { // 다음 턴 플레이어를 찾을 때까지 반복
                idx = (idx + 1) % n; // 다음 플레이어 인덱스로 순환
                tries++; // 카운터 +1
                if (tries > n) { pending = false; break; } // 한 바퀴 다 돌았으면 루프 중단
                Player storage c = g.players[idx]; // 다음 후보 플레이어 객체 가져오기
                if (!c.hasFolded && !c.isAllIn && c.lastAction == PlayerAction.NONE) break; // 다음 턴 진행 가능한 플레이어를 찾으면 루프 중단
            } while (true);
            if (tries <= n) { g.currentPlayerIdx = idx; } else { _showdown(gameId); } // 다음 플레이어를 찾았으면 인덱스 업데이트, 못찾았으면 쇼다운
        } else { // 더 이상 행동할 플레이어가 없으면 쇼다운
            _showdown(gameId);
        }
    }

    // 게임 결과(쇼다운)를 처리하는 내부 함수
    function _showdown(uint8 gameId) internal {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        g.phase = GamePhase.SHOWDOWN; // 게임 상태를 '쇼다운'으로 변경

        uint8 n = g.playerCount; // 전체 플레이어 수
        address winner; // 승자 주소
        uint8   highest; // 가장 높은 카드 숫자
        uint8   tieCount; // 무승부인 플레이어 수
        address[6] memory tied; // 가장 높은 카드를 가진 플레이어들을 저장하는 배열

        // 가장 높은 카드를 가진 플레이어 찾기
        for (uint8 i = 0; i < n; i++) {
            Player storage p = g.players[i]; // 각 플레이어 객체 불러오기
            if (!p.hasFolded) { // 포기하지 않은 플레이어 중에서
                if (p.card > highest) { highest = p.card; tieCount = 0; tied[tieCount++] = p.addr; } // 더 높은 카드가 나오면 최고기록 갱신 및 무승부 리셋
                else if (p.card == highest) { tied[tieCount++] = p.addr; } // 최고 카드와 같으면 무승부 배열에 추가
            }
        }
        if (tieCount == 1) { winner = tied[0]; } // 무승부가 아니면 첫 번째 저장된 플레이어가 승리
        else { // 무승부 상태이면
            address[] memory t2 = new address[](tieCount); // 무승부 플레이어 수만큼 새 배열 생성
            for (uint8 i = 0; i < tieCount; i++) t2[i] = tied[i]; // 무승부 상태인 플레이어들을 새 배열에 복사
            winner = _resolveDraw(g, t2); // 무승부를 처리하는 함수로 최종 승자 판별
        }

        // 쇼다운 시 최소 배팅액 계산(올인 처리)
        uint8 minContribution = type(uint8).max; // 최소 배팅액을 찾기 위해 최대값으로 초기화
        for (uint8 i = 0; i < n; i++) { // 모든 플레이어를 순회
            Player storage p = g.players[i]; // 각 플레이어 객체 불러오기
            if (!p.hasFolded) { // 포기하지 않은 플레이어 중에서
                if (p.currentBet < minContribution) { // 현재 플레이어의 베팅액이 최소 배팅액보다 작으면
                    minContribution = p.currentBet; // 최소 배팅액 갱신
                }
            }
        }
        // 초과 베팅액 환불
        for (uint8 i = 0; i < n; i++) { // 모든 플레이어를 순회
            Player storage p = g.players[i]; // 각 플레이어 객체 불러오기
            if (!p.hasFolded) { // 포기하지 않은 플레이어 중에서
                uint8 excess = p.currentBet - minContribution; // 최소 배팅액 대비 초과 베팅액 계산
                if (excess > 0) { // 초과분이 있다면
                    p.chips += excess; // 초과분을 칩으로 돌려줌
                    g.pot -= excess; // 팟에서 초과분만큼 차감
                }
                p.currentBet = minContribution; // 모든 참여자의 베팅액을 최소 배팅액으로 통일
            }
        }

        // 승자에게 팟에 남은 칩 전부 지급
        Player storage winP = _getPlayerIndex(g, winner); // 승자 주소로 승자 객체 찾기
        uint8 winAmt = g.pot; // 팟의 모든 칩을 승리 금액으로 설정
        winP.chips += winAmt; // 승자의 칩에 승리 금액 추가
        g.pot = 0; // 다음 라운드를 위해 팟을 0으로 초기화

        emit Showdown(gameId, winner, winAmt); // 쇼다운 이벤트 호출 (승자, 승리 금액)
        _nextRoundOrEnd(gameId, winner); // 다음 라운드 또는 게임 종료 처리 함수 호출
    }

    // 무승부 처리 내부 함수: 카드를 다시 받아 단판 승부
    function _resolveDraw(Game storage g, address[] memory tiedPlayers) internal returns (address) {
        uint8 newHighest; // 재대결의 가장 높은 카드
        uint8 newTieCount; // 재대결에서 무승부인 플레이어 수
        address[] memory newTied = new address[](tiedPlayers.length); // 재대결 결과를 저장할 배열
        for (uint8 i = 0; i < tiedPlayers.length; i++) { // 무승부인 플레이어들만 순회
            address pa = tiedPlayers[i]; // 플레이어 주소
            uint8 c = _dealCard(g); // 카드 새로 뽑기
            Player storage p = _getPlayerIndex(g, pa); // 플레이어 객체 찾기
            p.card = c; // 새 카드 전달
            emit TieBreakerCard(pa, c); // 재대결 카드 이벤트 호출

            if (c > newHighest) { newHighest = c; newTieCount = 0; newTied[newTieCount++] = pa; } // 더 높은 카드 나오면 기록 갱신
            else if (c == newHighest) { newTied[newTieCount++] = pa; } // 또 동점이면 무승부 배열에 추가
        }
        if (newTieCount == 1) { return newTied[0]; } // 재대결에서 승자가 나왔으면 승자 주소 리턴
        address[] memory nextTied = new address[](newTieCount); // 또 무승부 상태라면
        for (uint8 i = 0; i < newTieCount; i++) { nextTied[i] = newTied[i]; } // 다음 재대결을 위해 플레이어 목록 복사
        return _resolveDraw(g, nextTied); // 승자가 나올 때까지 무승부 함수 다시 실행
    }

    // 플레이어가 1명 남았을 때 라운드를 즉시 종료하는 함수
    function _endRoundEarly(uint8 gameId) internal {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        address winner; // 승자 주소
        uint8 n = g.playerCount; // 전체 플레이어 수
        for (uint8 i = 0; i < n; i++) { // 모든 플레이어를 순회
            Player storage p = g.players[i]; if (!p.hasFolded) { winner = p.addr; break; } // 포기하지 않은 유일한 플레이어를 승자로 지정
        }
        Player storage winP = _getPlayerIndex(g, winner); // 승자 객체 찾기
        winP.chips += g.pot; // 승자에게 팟의 모든 칩 지급
        uint8 winAmt = g.pot; // 승리 금액 기록
        g.pot = 0; // 팟 초기화
        emit Showdown(gameId, winner, winAmt); // 쇼다운 이벤트 호출
        _nextRoundOrEnd(gameId, winner); // 다음 라운드 또는 게임 종료 처리 함수 호출
    }

    // 다음 라운드를 시작하거나, 최종 승자가 나왔으면 게임을 종료하는 함수
    function _nextRoundOrEnd(uint8 gameId, address winner) internal {
        Game storage g = games[gameId]; // 함수 내 게임 객체 g 생성
        uint8 n = g.playerCount; // 전체 플레이어 수
        uint8 target = ENTRY_FEE_CHIPS * n; // 게임의 총 칩 개수 (최종 승리 목표)
        uint8 winnerIdx; // 승자의 인덱스

        // 다음 라운드를 위해 모든 플레이어의 상태 초기화
        for (uint8 i = 0; i < n; i++) {
            Player storage p = g.players[i]; // 각 플레이어 객체 불러오기
            p.card = 0; // 카드 리셋
            p.currentBet = 0; // 누적 배팅액 리셋
            p.lastAction = PlayerAction.NONE; // 마지막 행동 리셋
            p.isAllIn = false; // 올인 상태 리셋
            p.allInAmount = 0; // 올인 금액 리셋
            p.hasFolded = false; // 포기 상태 리셋

            if (g.players[i].addr == winner) winnerIdx = i; // 이번 라운드 승자의 인덱스 저장
            if (g.players[i].chips == target) { // 어떤 플레이어가 모든 칩을 다 가져갔다면
                address payable payWinner = payable(winner); // 최종 승자의 주소를 payable로 변환
                uint256 balance = address(this).balance; // 컨트랙트에 모인 이더 잔액 확인
                if (balance > 0) { payWinner.transfer(balance); } // 잔액이 있다면 최종 승자에게 모두 전송
                g.phase = GamePhase.FINISHED; // 게임 상태를 '종료'로 변경
                // 모든 플레이어의 게임 참가 기록 초기화
                for (uint8 j = 0; j < n; j++) {
                    playerGameId[g.players[j].addr] = 0; // 플레이어의 게임 아이디를 0으로 변경하여 게임에서 나가도록 처리
                }
                return; // 게임이 종료되었으므로 함수 종료
            }
        }
        // 게임이 아직 끝나지 않았다면 다음 라운드 준비
        g.currentBet = 0; // 최고 배팅액 0으로 초기화
        g.activeCount = n; // 활성 플레이어 수를 전체 인원으로 초기화 (칩 없는 플레이어는 아래서 제외됨)
        g.pot = 0; // 팟 초기화

        // 다음 라운드 시작
        g.phase = GamePhase.BETTING; // 게임 상태를 '배팅중'으로 변경
        g.currentBet = 0; // 최고 배팅액 0
        _initDeck(g); // 덱을 새로 섞음

        g.currentPlayerIdx = winnerIdx; // 이전 라운드 승자가 선 플레이어가 됨
        g.pot = 0; // 팟 0
        g.activeCount = 0; // 활성 플레이어 수 다시 계산 시작
        for (uint8 i = 0; i < n; i++) { 
            Player storage pl = g.players[i]; // 각 플레이어 객체 불러오기
            if (pl.chips >= 1) { // 칩이 1개 이상 있다면
                pl.chips--; // 칩 1개 배팅
                pl.currentBet = 1; // 누적 배팅 1
                g.pot++; // 팟에 1개 추가
            } else if (pl.chips > 0) { // 칩이 1개보다 적게 남았다면 (이 경우는 없어야 함)
                g.pot += pl.chips; // 남은 칩 모두 배팅
                pl.chips = 0; // 칩 0
                pl.hasFolded = true; // 자동으로 폴드 처리
            } else { pl.hasFolded = true; } // 칩이 아예 없다면 폴드 처리
        }
        g.currentBet = 1; // 라운드 최고 배팅액은 1로 시작
        for (uint8 i = 0; i < n; i++) { if (!g.players[i].hasFolded) g.activeCount++; } // 폴드하지 않은 플레이어 수 계산
        for (uint8 i = 0; i < n; i++) { // 폴드하지 않은 플레이어에게 카드 분배
            if (!g.players[i].hasFolded) {
                uint8 d = _dealCard(g); // 카드 뽑기
                g.players[i].card = d; // 플레이어에게 카드 전달
                emit CardDealt(gameId, g.players[i].addr); // 카드 분배 이벤트 호출
            }
        }
    }

    // 게임의 모든 플레이어 칩 보유량 조회
    function viewAllChips(uint8 gameId) external view onlyActive(gameId) returns (address[] memory, uint8[] memory) {
        Game storage g = games[gameId]; // 해당 게임 객체 불러오기
        uint8 n = g.playerCount; // 전체 플레이어 수
        address[] memory addrs = new address[](n); // 플레이어 주소를 저장할 배열
        uint8[]   memory chips = new uint8[](n); // 플레이어 칩 수를 저장할 배열
        for (uint8 i = 0; i < n; i++) { // 모든 플레이어를 순회
            addrs[i] = g.players[i].addr; // 주소를 차례로 저장
            chips[i] = g.players[i].chips; // 칩 수를 차례로 저장
        }
        return (addrs, chips); // 주소 배열과 칩 배열을 같이 리턴
    }

    // 자신을 제외한 다른 플레이어들의 카드 확인
    function viewCards(uint8 gameId) external view onlyActive(gameId) onlyInGame(gameId) returns (address[] memory, uint8[] memory) {
        Game storage g = games[gameId]; // 해당 게임 객체 불러오기
        uint8 n = g.playerCount - 1; // 나를 제외한 플레이어 수
        address[] memory addrs = new address[](n); // 상대방 주소를 저장할 배열
        uint8[]   memory cards = new uint8[](n); // 상대방 카드를 저장할 배열
        uint8 idx; // 배열 인덱스
        for (uint8 i = 0; i < g.playerCount; i++) { // 모든 플레이어를 순회
            if (g.players[i].addr != msg.sender) { // 함수 호출자가 아닌 플레이어일 경우
                addrs[idx] = g.players[i].addr; // 주소를 배열에 저장
                cards[idx] = g.players[i].card; // 카드를 배열에 저장
                idx++; // 인덱스 +1
            }
        }
        return (addrs, cards); // 상대방들의 주소와 카드 배열을 리턴
    }

    // 주소에 해당하는 플레이어 객체를 반환하는 내부 함수
    function _getPlayerIndex(Game storage g, address addr) internal view returns (Player storage) {
        for (uint8 i = 0; i < g.playerCount; i++) { // 모든 플레이어를 순회
            if (g.players[i].addr == addr) { // 찾는 주소와 일치하면
                return g.players[i]; // 해당 플레이어 객체 리턴
            }
        }
        revert("No such player"); // 플레이어를 찾지 못하면 실행 중단
    }

    // 특정 플레이어를 제외한 나머지 플레이어들의 액션 상태를 초기화
    function _resetActions(Game storage g, uint8 actorIdx) internal {
        for (uint8 i = 0; i < g.playerCount; i++) { // 모든 플레이어를 순회
            if (i != actorIdx) { // 행동한 플레이어 자신이 아닐 경우
                Player storage pl = g.players[i]; // 플레이어 객체 불러오기
                if (!pl.hasFolded && !pl.isAllIn) pl.lastAction = PlayerAction.NONE; // 폴드나 올인 상태가 아니면 마지막 행동을 '없음'으로 리셋
            }
        }
    }

    // 덱을 초기화하고 셔플하는 내부 함수
    function _initDeck(Game storage g) internal {
        uint8 idx; // 덱 생성용 인덱스
        for (uint8 v = 1; v <= 10; v++) { // 1부터 10까지의 숫자에 대해
            g.deck[idx++] = v; // 각 숫자의 카드를 두 장씩
            g.deck[idx++] = v; // 덱에 추가
        }
        // Fisher-Yates 알고리즘을 이용한 셔플 (chat gpt를 통해 제작)
        for (uint8 i = 19; i > 0; i--) {
            uint8 j = uint8(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, i))) % (i + 1)); // 무작위 인덱스 j 생성
            (g.deck[i], g.deck[j]) = (g.deck[j], g.deck[i]); // i번째 카드와 j번째 카드 교환
        }
        g.deckIndex = 0; // 덱 인덱스를 0으로 초기화해서 첫 번째 카드부터 뽑도록 설정
    }

    // 덱에서 카드 한 장을 나눠주는 내부 함수
    function _dealCard(Game storage g) internal returns (uint8) {
        if (g.deckIndex >= 20) { _initDeck(g); } // 덱의 20장 카드를 모두 소진했으면 다시 새로 섞음
        return g.deck[g.deckIndex++]; // 현재 덱 인덱스의 카드를 리턴하고 인덱스를 1 증가시킴
    }

    // 컨트랙트에 쌓인 모든 이더를 오너에게 전송 (비상 출금용)
    function withdrawBalance() external onlyOwner() {
        uint256 bal = address(this).balance; // 컨트랙트의 이더 잔액을 bal에 저장
        require(bal > 0, "No balance to withdraw"); // 출금할 잔액이 있는지 확인
        payable(owner).transfer(bal); // 오너에게 모든 잔액 전송
    }
}