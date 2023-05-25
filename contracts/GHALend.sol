// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IERC20 {
    function decimals() external view returns (uint8);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IGMDVault {
    struct PoolInfo {
        IERC20 lpToken;
        IERC20 GDlptoken;
        uint256 EarnRateSec;     
        uint256 totalStaked;
        uint256 lastUpdate;
        uint256 vaultcap;
        uint256 glpFees;
        uint256 APR;
        bool stakable;
        bool withdrawable;
        bool rewardStart;
    }
    function poolInfo(uint256 _pid) external view returns (PoolInfo memory);
}

contract GHALend is Ownable, ReentrancyGuard {
    IGMDVault public GMDVault = IGMDVault(0x8080B5cE6dfb49a6B86370d6982B3e2A86FBBb08);
    uint256 public poolId;
    IERC20 public gmdUSDC;
    IERC20 public USDC;
    uint256 private decimalAdj;

    uint256 public totalDeposits;
    uint256 public totalxDeposits;
    uint256 public totalBorrows;
    uint256 public totalxBorrows;
    uint256 public totalGmdDeposits;

    mapping(address => uint256) public xdeposits;
    mapping(address => uint256) public xborrows;
    mapping(address => uint256) public gmdDeposits;

    // security caps
    uint256 public depositCap    = 20000 * 1e18;
    uint256 public gmdDepositCap = 10000 * 1e18;
    uint256 public maxRate = 1.1 * 1e18;

    uint256 constant MAX_BPS    = 1e4;
    uint256 public LTV    = 0.8 * 1e4;   // 80% LTV
    uint256 public base   = 2 * 1e16;    // 2%
    uint256 public slope1 = 0.1 * 1e16;  // 0.1%
    uint256 public kink   = 80 * 1e16;   // 80%
    uint256 public slope2 = 1 * 1e16;    // 1%

    uint256 public earnRateSec;
    uint256 public lastUpdate;

    uint256 feeRate = 2500;
    address public treasury = 0x52D16E8550785F3F1073632bC54dAa2e07e60C1c;

    // Ratio to be paid out in esGHA
    uint256 esRatio = 8000;

    IERC20 public GHA = IERC20(0xeCA66820ed807c096e1Bd7a1A091cD3D3152cC79);
    IERC20 public esGHA = IERC20(0x3129F42a1b574715921cb65FAbB0F0f9bd8b4f39);

    // Timestamp of when the rewards finish
    uint public finishAt;
    // Minimum of last updated time and reward finish time
    uint public updatedAt;
    // Reward to be paid out per second
    uint public rewardRate;
    // Sum of (reward rate * dt * 1e18 / total supply)
    uint public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint) public rewards;

    // Initialize the lending pool with the poolId corresponding to the GMD vault
    constructor(uint256 _poolId) {
        poolId = _poolId;
        gmdUSDC = GMDVault.poolInfo(poolId).GDlptoken;
        USDC = GMDVault.poolInfo(poolId).lpToken;
        decimalAdj = 10 ** (18 - USDC.decimals()); // decimal handling
    }

    function deposit(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        accureInterest();
        USDC.transferFrom(msg.sender, address(this), _amount);
        require(_amount + totalDeposits <= depositCap, "GHALend: Deposit exceeds cap");
        uint256 xamount = _amount * decimalAdj * 1e18/usdPerxDeposit();
        xdeposits[msg.sender] += xamount;
        totalDeposits += _amount * decimalAdj;
        totalxDeposits += xamount;
        updateAPR();
    }

    function withdraw(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        accureInterest();
        uint256 deposits = xdeposits[msg.sender] * usdPerxDeposit()/1e18;
        uint256 xamount;
        if (_amount * decimalAdj > deposits) {
            // withdraw all
            xamount = xdeposits[msg.sender];
            xdeposits[msg.sender] -= xamount;
            totalDeposits -= deposits;
            USDC.transfer(msg.sender, deposits / decimalAdj);
        } else {
            xamount = _amount * decimalAdj * 1e18/usdPerxDeposit();
            xdeposits[msg.sender] -= xamount;
            totalDeposits -=_amount * decimalAdj;
            USDC.transfer(msg.sender, _amount);
        }
        totalxDeposits -= xamount;
        USDC.transfer(msg.sender, _amount);
        if (totalxDeposits == 0) { // transfer dust
            USDC.transfer(treasury, USDC.balanceOf(address(this)));
        }
        updateAPR();
    }

    function depositGmd(uint256 _amount) external nonReentrant {
        gmdUSDC.transferFrom(msg.sender, address(this), _amount);
        require(_amount + totalGmdDeposits <= gmdDepositCap, "GHALend: Deposit exceeds cap");
        gmdDeposits[msg.sender] += _amount;
        totalGmdDeposits += _amount;
    }
    function withdrawGmd(uint256 _amount) external nonReentrant {
        accureInterest();
        uint256 freeUSD;
        if (LTV == 0){
            require(xborrows[msg.sender] == 0, "GHALend: Insufficient collateral");
            freeUSD = valueOfDeposits(msg.sender);
        } else {
            freeUSD = valueOfDeposits(msg.sender)
                - xborrows[msg.sender] * usdPerxBorrow()/1e18 / LTV*MAX_BPS;
        }
        uint256 freeCollateral = freeUSD * 1e18/usdPerGmdUSDC();
        require(freeCollateral >= _amount, "GHALend: Insufficient collateral");
        gmdDeposits[msg.sender] -= _amount;
        totalGmdDeposits -= _amount;
        gmdUSDC.transfer(msg.sender, _amount);
    }

    function borrow(uint256 _amount) external nonReentrant {
        accureInterest();
        uint256 totalBorrowable = valueOfDeposits(msg.sender) * LTV/MAX_BPS;
        uint256 borrowable = totalBorrowable - xborrows[msg.sender] * usdPerxBorrow()/1e18;
        require(_amount * decimalAdj <= borrowable, "GHALend: Insufficient collateral");
        uint256 xamount = _amount * decimalAdj * 1e18/usdPerxBorrow();
        xborrows[msg.sender] += xamount;
        totalBorrows += _amount * decimalAdj;
        totalxBorrows += xamount;
        USDC.transfer(msg.sender, _amount);
        updateAPR();
    }

    function repay(uint256 _amount) external nonReentrant {
        accureInterest();
        uint256 borrows = xborrows[msg.sender] * usdPerxBorrow()/1e18;
        uint256 xamount;
        if (_amount * decimalAdj > borrows) {
            // repay all
            xamount = xborrows[msg.sender];
            USDC.transferFrom(msg.sender, address(this), borrows / decimalAdj);
            totalBorrows -= borrows;
        } else {
            xamount = _amount * decimalAdj * 1e18/usdPerxBorrow();
            USDC.transferFrom(msg.sender, address(this), _amount);
            totalBorrows -= _amount * decimalAdj;
        }
        xborrows[msg.sender] -= xamount;
        totalxBorrows -= xamount;
        updateAPR();
    }

    // returns how much one gmdUSDC is worth
    function usdPerGmdUSDC() internal view returns (uint256) {
        uint256 totalShares = gmdUSDC.totalSupply();
        uint256 calculatedRate = GMDVault.poolInfo(poolId).totalStaked * 1e18 / totalShares;
        return _min(calculatedRate, maxRate);
    }

    function usdPerxDeposit() internal view returns (uint256) {
        if (totalxDeposits == 0) {
            return 1e18;
        }
        return totalDeposits * 1e18 / totalxDeposits;
    }

    function usdPerxBorrow() internal view returns (uint256) {
        if (totalxBorrows == 0) {
            return 1e18;
        }
        return totalBorrows * 1e18 / totalxBorrows;
    }

    function borrowAPR() public view returns (uint256) {
        if (totalDeposits == 0) {
            return 0;
        }
        uint256 utilizationRatio = totalBorrows*1e18/totalDeposits;
        uint256 APR;

        if (utilizationRatio < kink) {
            APR = (slope1 * utilizationRatio*100) / 1e18 + base;
        } else {
            uint256 excessUtilization = utilizationRatio - kink;
            APR = (slope1 * kink*100) / 1e18 + (slope2 * excessUtilization*100) / 1e18 + base;
        }

        uint256 vaultAPR = GMDVault.poolInfo(poolId).APR*1e14;

        // APR cap
        if (LTV == 0) {
            return APR;
        }
        return _min(APR, vaultAPR * MAX_BPS / LTV);
    }

    // adds accrued interest
    function accureInterest() internal {
        uint256 reward = pendingInterest();
        lastUpdate = block.timestamp;
        uint256 fees = reward * feeRate / MAX_BPS;
        USDC.transfer(treasury, fees / decimalAdj);
        totalDeposits += (reward - fees);
        totalBorrows += reward;
    }
    function pendingInterest() public view returns (uint256) {
        uint256 timepass = block.timestamp - lastUpdate;
        return earnRateSec*timepass;
    }

    // updates APR
    function updateAPR() internal {
        earnRateSec = totalBorrows*borrowAPR()/1e18/(365 days);
    }

    // returns value of a user's collateral in usd
    function valueOfDeposits(address _user) internal view returns (uint256) {
        return (gmdDeposits[_user]*usdPerGmdUSDC())/1e18;
    }

    function updateMaxRate(uint256 _maxRate) external onlyOwner {
        maxRate = _maxRate;
    }
    function setDepositCaps(uint256 _depositCap, uint256 _gmdDepositCap) external onlyOwner {
        depositCap = _depositCap;
        gmdDepositCap = _gmdDepositCap;
    }

    function updateInterestRateCurve(uint256 _base, uint256 _slope1, uint256 _kink, uint256 _slope2) external onlyOwner {
        base = _base;
        slope1 = _slope1;
        kink = _kink;
        slope2 = _slope2;
    }

    function changeFees(uint256 _feeRate, address _treasury) external onlyOwner {
        require(_feeRate <= MAX_BPS, "out of range");
        feeRate = _feeRate;
        treasury = _treasury;
    }

    function changeEsRatio(uint256 _esRatio) external onlyOwner {
        require(_esRatio <= MAX_BPS, "out of range");
        esRatio = _esRatio;
    }

    // it is extremely rare for someone to approach a low health factor. in an emergency, owner can liquidate
    function governanceEmergencyLiquidate(address _user) external onlyOwner {
        gmdDeposits[owner()] += gmdDeposits[_user];
        xborrows[owner()] += xborrows[_user];
        gmdDeposits[_user] = 0;
        xborrows[_user] = 0;
    }

    function governanceRecoverUnsupported(IERC20 _token, address to, uint256 amount) external onlyOwner {
        require(_token != USDC);
        require(_token != gmdUSDC);
        _token.transfer(to, amount);
    }

    // modified synthetix staking:

    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        updatedAt = lastTimeRewardApplicable();

        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
        }

        _;
    }

    function lastTimeRewardApplicable() internal view returns (uint) {
        return _min(finishAt, block.timestamp);
    }

    function rewardPerToken() public view returns (uint) {
        if (totalxDeposits == 0) {
            return rewardPerTokenStored;
        }

        return
            rewardPerTokenStored +
            (rewardRate * (lastTimeRewardApplicable() - updatedAt) * 1e18) /
            totalxDeposits;
    }

    function earned(address _account) public view returns (uint) {
        return
            ((xdeposits[_account] *
                (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e18) +
            rewards[_account];
    }

    function getReward() external updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        rewards[msg.sender] = 0;
        esGHA.transfer(msg.sender, reward * esRatio / MAX_BPS);
        GHA.transfer(msg.sender, reward * (MAX_BPS - esRatio) / MAX_BPS);
    }

    function setRewards(uint256 _rewardRate, uint256 _finishAt) external onlyOwner updateReward(address(0)) {
        rewardRate = _rewardRate;
        finishAt = _finishAt;
        uint256 duration = finishAt - block.timestamp;
        require(
            rewardRate * duration * esRatio / MAX_BPS <= esGHA.balanceOf(address(this)),
            "escrowed reward amount > balance"
        );
        require(
            rewardRate * duration * (MAX_BPS - esRatio) / MAX_BPS <= GHA.balanceOf(address(this)),
            "reward amount > balance"
        );
    }

    function _min(uint x, uint y) private pure returns (uint) {
        return x <= y ? x : y;
    }
}
