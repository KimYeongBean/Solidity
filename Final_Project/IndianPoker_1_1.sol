// SPDX-License-Identifier: GPL-3.0
// Modified: Single global game, owner start, player exit

pragma solidity ^0.8.18;

contract IndianPoker_1_1 {
    // 카드 값: JOKER(0), TWO(1), ..., ACE(13)
    enum CardValue { 
        JOKER, TWO, THREE, FOUR, FIVE, SIX, SEVEN, EIGHT, NINE, TEN, JACK, QUEEN, KING, ACE
    }
    
    // 게임 진행 단계: 대기 → 베팅 → 공개 → 종료
    enum GamePhase { WAITING, BETTING, SHOWDOWN, FINISHED }
    
    // 플레이어 행동: 없음, 베팅, 콜, 레이즈, 폴드, 올인
    enum PlayerAction { NONE, BET, CALL, RAISE, FOLD, ALL_IN }
    
    // 플레이어 정보 구조체
    struct Player {
        address addr;           // 지갑 주소
        uint256 chips;          // 보유 칩 수
        CardValue card;         // 받는 카드 값
        bool isActive;          // 현재 게임에 남아있는 상태
        bool hasFolded;         // 폴드 여부
        uint256 currentBet;     // 이번 라운드에 베팅한 총액
        PlayerAction lastAction;// 마지막 행동 기록
        bool isAllIn;           // 올인 상태 여부
        uint256 allInAmount;    // 올인 시 걸어둔 금액
    }
    
    // --- 전역 상태 변수 ---
    GamePhase public phase;                   // 현재 게임 단계
    address public owner;                     // 방장(컨트랙트 생성자)
    Player[] public players;                  // 플레이어 목록 (배열)
    mapping(address => uint256) public playerIndex;  // 주소 → 배열 인덱스 매핑
    mapping(address => bool) public isInGame;        // 주소가 현재 게임에 참여 중인지 여부
    mapping(address => uint256) public playerChips;  // 주소별 칩 예치금
    mapping(address => uint256) public playerGameId; // (미사용, 이후 확장용)
    uint256 public pot;                       // 현재 팟에 쌓인 칩 총액
    uint256 public currentBet;                // 이번 라운드 최고 베팅 금액
    uint256 public currentPlayerIdx;          // 현재 턴인 플레이어 배열 인덱스
    uint256 public minBet;                    // 최소 베팅 단위
    uint256 public activeCount;               // 남아있는(폴드하지 않은) 플레이어 수

    // 상수 정의
    uint256 constant ENTRY_CHIPS = 20;        // 참가 시 지급하는 초기 칩
    uint256 constant CHIP_RATE = 20;          // 0.001 ETH → 20 칩 교환 비율
    uint256 constant EXCHANGE_RATE = 50000000000000; // 1 칩 → 0.00005 ETH
    uint256 constant ENTRY_FEE = 0.001 ether; // 입장 시 지급해야 하는 ETH

    // --- 이벤트 ---
    event PlayerJoined(address indexed player);
    event PlayerExited(address indexed player);
    event GameStarted();
    event PlayerActed(address indexed player, PlayerAction action, uint256 amount);
    event CardDealt(address indexed player, CardValue card);
    event GameEnded(address winner, uint256 amount);
    event ChipsPurchased(address player, uint256 chips);
    event ChipsExchanged(address player, uint256 chips, uint256 ethAmount);

    // --- 수식어 (Modifiers) ---
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner"); _;
    }
    modifier inPhase(GamePhase p) {
        require(phase == p, "Invalid phase"); _;
    }
    modifier onlyPlayerActive() {
        require(isInGame[msg.sender], "Not in game"); _;
    }

    // --- 생성자 ---
    constructor() {
        owner = msg.sender;        // 컨트랙트 배포자가 오너
        phase = GamePhase.WAITING; // 초기 상태: 대기
        minBet = 1;                // 최소 베팅 단위 설정
    }

    // --- 칩 구매 ---
    function getChip() external payable {
        // 0.001 ETH 단위로만 보내도록 검증
        require(msg.value >= ENTRY_FEE && msg.value % ENTRY_FEE == 0, "0.001 ETH increments");
        uint256 chips = (msg.value * CHIP_RATE) / ENTRY_FEE;
        // 이미 게임에 참여 중이면 곧바로 칩을 증가
        if (isInGame[msg.sender]) {
            players[playerIndex[msg.sender]].chips += chips;
        }
        emit ChipsPurchased(msg.sender, chips);
    }
    
    // --- 칩 환전 ---
    function exchange(uint256 chipAmount) external {
        require(chipAmount > 0, ">0");
        require(!isInGame[msg.sender], "Leave game to exchange"); // 게임 참가 중에는 환전 불가
        uint256 ethAmt = chipAmount * EXCHANGE_RATE;
        require(address(this).balance >= ethAmt, "Insufficient contract ETH");
        payable(msg.sender).transfer(ethAmt);
        emit ChipsExchanged(msg.sender, chipAmount, ethAmt);
    }

    // --- 게임 참가 ---
    function joinGame() external payable inPhase(GamePhase.WAITING) {
        Player memory p;
        if(p.chips >= ENTRY_CHIPS){ // 20칩 이상 보유 확인
            require(!isInGame[msg.sender], "Already in game");
            require(msg.value == ENTRY_FEE, "Send 0.001 ETH to join");
            require(players.length < 6, "Max 6 players"); // 최대 6명 제한
            
            p.addr = msg.sender;
            p.isActive = true;       // 활성 상태
            players.push(p);
            playerIndex[msg.sender] = players.length - 1;
            isInGame[msg.sender] = true;
            activeCount++;
            emit PlayerJoined(msg.sender);
        }
        
    }

    // --- 게임 중도 탈퇴 ---
    function exitGame() external onlyPlayerActive {
        uint idx = playerIndex[msg.sender];
        Player storage p = players[idx];
        require(phase == GamePhase.WAITING || p.isActive, "Cannot exit now");
        
        // 보유 칩을 되돌려 줌
        playerChipsTransfer(msg.sender, p.chips);
        
        // 배열에서 제거하는 대신 상태만 비활성화
        p.isActive = false;
        isInGame[msg.sender] = false;
        activeCount--;
        emit PlayerExited(msg.sender);
    }

    // --- 게임 시작 (오너만 호출 가능) ---
    function startGame() external onlyOwner inPhase(GamePhase.WAITING) {
        require(activeCount >= 2, "Need >=2"); // 최소 2명 필요
        phase = GamePhase.BETTING;
        currentBet = 0;
        pot = 0;
        currentPlayerIdx = 0; // 배열 인덱스 0번부터 시작
        
        // 과거 라운드 데이터 초기화
        for(uint i=0;i<players.length;i++){
            Player storage p = players[i];
            if(p.isActive){ 
                p.hasFolded = false;
                p.currentBet = 0;
                p.lastAction = PlayerAction.NONE;
                p.isAllIn = false;
                p.allInAmount = 0;
            }
        }
        
        // 카드 배분: 활성 플레이어마다 해시를 통해 0~13 랜덤 선택
        for(uint i=0;i<players.length;i++){
            if(players[i].isActive){
                uint val = uint(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, i))) % 14;
                players[i].card = CardValue(val);
                emit CardDealt(players[i].addr, players[i].card);
            }
        }
        emit GameStarted();
    }

    // --- 베팅 ---
    function bet(uint256 amount) external inPhase(GamePhase.BETTING) onlyPlayerActive {
        Player storage p = players[playerIndex[msg.sender]];
        require(p.isActive && !p.hasFolded, "Not active");
        require(amount >= minBet && p.chips >= amount, "Invalid bet");
        require(p.lastAction == PlayerAction.NONE, "Already acted");
        
        p.chips -= amount;
        p.currentBet += amount;
        pot += amount;
        if(p.currentBet > currentBet) currentBet = p.currentBet;
        p.lastAction = PlayerAction.BET;
        emit PlayerActed(msg.sender, PlayerAction.BET, amount);
        advanceTurn(); // 다음 턴으로 넘어감
    }
    
    // --- 콜 or 올인 ---
    function callAction() external inPhase(GamePhase.BETTING) onlyPlayerActive {
        Player storage p = players[playerIndex[msg.sender]];
        uint need = currentBet - p.currentBet;
        require(need > 0 && p.chips > 0, "Nothing to call");
        uint callAmt = p.chips <= need ? p.chips : need;
        p.chips -= callAmt;
        p.currentBet += callAmt;
        pot += callAmt;
        if(callAmt < need) { 
            // 내 칩이 부족해서 올인 처리
            p.isAllIn = true;
            p.allInAmount = p.currentBet;
            p.lastAction = PlayerAction.ALL_IN;
            emit PlayerActed(msg.sender, PlayerAction.ALL_IN, callAmt);
        } else {
            // 정상 콜
            p.lastAction = PlayerAction.CALL;
            emit PlayerActed(msg.sender, PlayerAction.CALL, callAmt);
        }
        advanceTurn();
    }

    // --- 레이즈 ---
    function raise(uint256 raiseAmt) external inPhase(GamePhase.BETTING) onlyPlayerActive {
        Player storage p = players[playerIndex[msg.sender]];
        uint need = currentBet - p.currentBet;
        uint total = need + raiseAmt;
        require(raiseAmt > 0 && p.chips >= total, "Invalid raise");
        p.chips -= total;
        p.currentBet += total;
        pot += total;
        currentBet = p.currentBet;
        p.lastAction = PlayerAction.RAISE;
        // 다른 활성 플레이어들의 lastAction 필드를 초기화 → 다시 행동 기회 부여
        for(uint i=0;i<players.length;i++){ 
            if(players[i].isActive && players[i].addr != msg.sender) 
                players[i].lastAction = PlayerAction.NONE; 
        }
        emit PlayerActed(msg.sender, PlayerAction.RAISE, raiseAmt);
        advanceTurn();
    }

    // --- 폴드 ---
    function fold() external inPhase(GamePhase.BETTING) onlyPlayerActive {
        Player storage p = players[playerIndex[msg.sender]];
        p.hasFolded = true;
        p.isActive = false;
        activeCount--;
        p.lastAction = PlayerAction.FOLD;
        // 에이스 패널티: 에이스 들고 폴드 시 칩의 절반(홀수면 +1) 팟에 추가
        if(p.card == CardValue.ACE && p.chips > 0) {
            uint256 pen = p.chips / 2;
            if(p.chips % 2 == 1) pen++;
            p.chips -= pen;
            pot += pen;
        }
        emit PlayerActed(msg.sender, PlayerAction.FOLD, 0);
        // 남은 플레이어가 한 명이면 바로 종료, 아니면 턴 이동
        if(activeCount == 1) finishGame(); else advanceTurn();
    }

    // --- 다음 턴으로 이동 (내부 함수) ---
    function advanceTurn() internal {
        uint start = currentPlayerIdx;
        do {
            currentPlayerIdx = (currentPlayerIdx + 1) % players.length;
            Player storage np = players[currentPlayerIdx];
            // 활성 상태이고 폴드하지 않았으며, 아직 이번 라운드에 행동하지 않은 플레이어가 있으면 그쪽으로 턴 이동
            if(np.isActive && !np.hasFolded && np.lastAction == PlayerAction.NONE) return;
        } while(currentPlayerIdx != start);
        // 돌아와도 새로운 행동 대상자가 없으면 쇼다운으로 이동
        finishGame();
    }

    // --- 게임 종료 및 쇼다운 (내부 함수) ---
    function finishGame() internal {
        phase = GamePhase.SHOWDOWN;
        // 가장 높은 카드 가진 플레이어 찾기
        address winner;
        CardValue best;
        for(uint i=0;i<players.length;i++){
            Player storage p = players[i];
            if(p.isActive && !p.hasFolded) {
                if(winner == address(0) || compareCards(p.card, best)) {
                    winner = p.addr;
                    best = p.card;
                }
            }
        }
        require(winner != address(0), "No winner");
        // 승자에게 팟 전액 지급
        players[playerIndex[winner]].chips += pot;
        emit GameEnded(winner, pot);
        phase = GamePhase.FINISHED;
        // 패자들은 남은 칩을 되돌려 보유 칩에 추가
        for(uint i=0;i<players.length;i++){
            Player storage p = players[i];
            if(p.addr != winner) {
                playerChipsTransfer(p.addr, p.chips);
            }
            // 게임 참여 상태 초기화
            playerGameId[p.addr] = 0;
            isInGame[p.addr] = false;
        }
        autoReset(); // 내부적으로 모든 상태 초기화
    }

    // --- 게임 초기화 (내부 함수) ---
    function autoReset() internal {
        delete players;            // 플레이어 배열 비우기
        phase = GamePhase.WAITING; // 대기 상태로 돌아감
        pot = 0;
        currentBet = 0;
        activeCount = 0;
    }

    // --- 카드 비교 (내부 함수) ---
    function compareCards(CardValue c1, CardValue c2) internal pure returns(bool) {
        // 조커가 ACE(높음)보다 이김. 그 외는 단순 비교
        if(c1 == CardValue.JOKER && c2 == CardValue.ACE) return true;
        if(c1 == CardValue.JOKER && c2 != CardValue.ACE) return false;
        if(c2 == CardValue.JOKER && c1 == CardValue.ACE) return false;
        if(c2 == CardValue.JOKER && c1 != CardValue.ACE) return true;
        return uint8(c1) > uint8(c2);
    }

    // --- 칩 반환 헬퍼 함수 ---
    function playerChipsTransfer(address to, uint256 amount) internal {
        playerChips[to] += amount;
    }
}
