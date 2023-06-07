// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    function GDpriceToStakedtoken(uint256 _pid) external view returns(uint256);
    function leave(uint256 _share, uint256 _pid) external returns(uint256);
}

contract GHALend is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IGMDVault public constant GMDVault = IGMDVault(0x8080B5cE6dfb49a6B86370d6982B3e2A86FBBb08);
    uint256 public immutable pid;
    IERC20 public immutable gmdUSDC;
    IERC20 public immutable USDC;
    uint256 private immutable decimalAdj;

    uint256 public totalDeposits;
    uint256 public totalxDeposits;
    uint256 public totalBorrows;
    uint256 public totalxBorrows;
    uint256 public totalGmdDeposits;

    mapping(address => uint256) public xdeposits;
    mapping(address => uint256) public xborrows;
    mapping(address => uint256) public gmdDeposits;

    // security caps
    uint256 public maxRate = 999 * 1e18; // change before deployment
    uint256 public depositCap    = 20000 * 1e18;
    uint256 public gmdDepositCap = 10000 * 1e18;
    uint256 public borrowCap     = 10000 * 1e18;

    uint256 constant MAX_BPS = 1e4;
    uint256 public LTV       = 0.8 * 1e4;  // can borrow up to 80% LTV
    uint256 public redLTV    = 0.9 * 1e4;  // can be redeemed against above 90% LTV

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

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event DepositGmd(address indexed user, uint256 amount);
    event WithdrawGmd(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Redeem(address indexed user, address indexed executor, uint256 amount);
    event GetReward(address indexed user, uint256 amount);


    // Initialize the lending pool with the pool id corresponding to the GMD vault
    constructor(uint256 _pid, uint256 _decimalGap) {
        pid = _pid;
        gmdUSDC = GMDVault.poolInfo(pid).GDlptoken;
        USDC = GMDVault.poolInfo(pid).lpToken;
         // decimal handling. eg: gmdUSDC and USDC gap 12 decimals
        decimalAdj = 10 ** _decimalGap;
    }

    function deposit(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        accrueInterest();
        require(_amount * decimalAdj + totalDeposits <= depositCap, "GHALend: Deposit exceeds cap");
        uint256 xamount = _amount * decimalAdj * 1e18/usdPerxDeposit();
        require(xamount != 0);
        USDC.safeTransferFrom(msg.sender, address(this), _amount);
        xdeposits[msg.sender] += xamount;
        totalDeposits += _amount * decimalAdj;
        totalxDeposits += xamount;
        updateAPR();
        emit Deposit(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        accrueInterest();
        uint256 deposits = xdeposits[msg.sender] * usdPerxDeposit()/1e18;
        uint256 xamount;
        if (_amount * decimalAdj > deposits) {
            // withdraw all
            xamount = xdeposits[msg.sender];
            xdeposits[msg.sender] -= xamount;
            totalDeposits -= deposits;
            USDC.safeTransfer(msg.sender, deposits / decimalAdj);
            emit Withdraw(msg.sender, deposits / decimalAdj);
        } else {
            xamount = _amount * decimalAdj * 1e18/usdPerxDeposit() + 1;
            xdeposits[msg.sender] -= xamount;
            totalDeposits -=_amount * decimalAdj;
            USDC.safeTransfer(msg.sender, _amount);
            emit Withdraw(msg.sender, _amount);
        }
        totalxDeposits -= xamount;
        updateAPR();
    }

    function depositGmd(uint256 _amount) external nonReentrant {
        require(_amount + totalGmdDeposits <= gmdDepositCap, "GHALend: Deposit exceeds cap");
        gmdUSDC.safeTransferFrom(msg.sender, address(this), _amount);
        gmdDeposits[msg.sender] += _amount;
        totalGmdDeposits += _amount;
        emit DepositGmd(msg.sender, _amount);
    }
    function withdrawGmd(uint256 _amount) external nonReentrant {
        accrueInterest();
        uint256 freeUSD;
        if (LTV == 0) {
            require(xborrows[msg.sender] == 0, "GHALend: Insufficient collateral");
            freeUSD = valueOfDeposits(msg.sender);
        } else {
            freeUSD = valueOfDeposits(msg.sender)
                - xborrows[msg.sender] * usdPerxBorrow()/1e18 * MAX_BPS/LTV;
        }
        uint256 freeCollateral = freeUSD * 1e18/usdPerGmdUSDC();
        require(freeCollateral >= _amount, "GHALend: Insufficient collateral");
        gmdDeposits[msg.sender] -= _amount;
        totalGmdDeposits -= _amount;
        gmdUSDC.safeTransfer(msg.sender, _amount);
        emit WithdrawGmd(msg.sender, _amount);
    }

    function borrow(uint256 _amount) external nonReentrant {
        accrueInterest();
        require(_amount * decimalAdj + totalBorrows <= borrowCap, "GHALend: Borrow exceeds cap");
        uint256 totalBorrowable = valueOfDeposits(msg.sender) * LTV/MAX_BPS;
        uint256 usdPerxB = usdPerxBorrow();
        uint256 borrowable = totalBorrowable - xborrows[msg.sender] * usdPerxB/1e18;
        require(_amount * decimalAdj < borrowable, "GHALend: Insufficient collateral");
        uint256 xamount = _amount * decimalAdj * 1e18/usdPerxB;
        require(xamount != 0);
        xborrows[msg.sender] += xamount;
        totalBorrows += _amount * decimalAdj;
        totalxBorrows += xamount;
        USDC.safeTransfer(msg.sender, _amount);
        updateAPR();
        emit Borrow(msg.sender, _amount);
    }

    function repay(uint256 _amount) external nonReentrant {
        accrueInterest();
        uint256 borrows = xborrows[msg.sender] * usdPerxBorrow()/1e18 + 1;
        uint256 xamount;
        if (_amount * decimalAdj > borrows) {
            // repay all
            xamount = xborrows[msg.sender];
            USDC.safeTransferFrom(msg.sender, address(this), borrows/ decimalAdj + 1);
            totalBorrows -= borrows;
            emit Repay(msg.sender, borrows / decimalAdj);
        } else {
            xamount = _amount * decimalAdj * 1e18/usdPerxBorrow();
            USDC.safeTransferFrom(msg.sender, address(this), _amount);
            totalBorrows -= _amount * decimalAdj;
            emit Repay(msg.sender, _amount);
        }
        xborrows[msg.sender] -= xamount;
        totalxBorrows -= xamount;
        updateAPR();
    }

    // returns how much one gmdUSDC is worth
    function usdPerGmdUSDC() public view returns (uint256) {
        return _min(GMDVault.GDpriceToStakedtoken(pid), maxRate);
    }

    function usdPerxDeposit() public view returns (uint256) {
        if (totalxDeposits == 0) {
            return 1e18;
        }
        return (totalDeposits + pendingInterest() * (MAX_BPS - feeRate) / MAX_BPS) * 1e18 / totalxDeposits;
    }

    function usdPerxBorrow() public view returns (uint256) {
        if (totalxBorrows == 0) {
            return 1e18;
        }
        return (totalBorrows + pendingInterest()) * 1e18 / totalxBorrows;
    }

    function borrowAPR() public view returns (uint256) {
        if (totalDeposits == 0 || totalBorrows == 0) {
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

        uint256 vaultAPR = GMDVault.poolInfo(pid).APR*1e14;

        // APR cap
        if (LTV == 0) {
            return APR;
        }
        return _min(APR, vaultAPR * MAX_BPS / LTV);
    }

    // adds accrued interest
    function accrueInterest() internal {
        uint256 reward = pendingInterest();
        lastUpdate = block.timestamp;
        uint256 fees = reward * feeRate / MAX_BPS;
        totalDeposits += (reward - fees);
        totalBorrows += reward;
        // treasury deposits fees back into protocol
        uint256 usdPerxD = usdPerxDeposit();
        xdeposits[treasury] += fees * 1e18/usdPerxD;
        totalxDeposits += fees * 1e18/usdPerxD;
        totalDeposits += fees;
    }
    function pendingInterest() internal view returns (uint256) {
        uint256 timepass = block.timestamp - lastUpdate;
        return earnRateSec*timepass;
    }

    // updates APR
    function updateAPR() internal {
        // function is always called after accrueInterest() so totalBorrows refers to the true value
        earnRateSec = totalBorrows*borrowAPR()/1e18/(365 days);
    }

    // returns value of a user's collateral in usd
    function valueOfDeposits(address _user) internal view returns (uint256) {
        return gmdDeposits[_user] * usdPerGmdUSDC()/1e18;
    }

    function userLTV(address _user) public view returns (uint256) {
        if(valueOfDeposits(_user) == 0) {
            return 0;
        }
        return xborrows[_user] * usdPerxBorrow() / valueOfDeposits(_user);
    }

    // redeem USDC -> gmdUSDC at redemption price with no deposit fee
    function redeem(address _user, uint256 _amount) external nonReentrant {
        accrueInterest();
        uint256 gmdAmount = _amount * decimalAdj * 1e18/usdPerGmdUSDC();
        uint256 usdPerxB = usdPerxBorrow();
        xborrows[_user] -= _amount * decimalAdj * 1e18/usdPerxB;
        gmdDeposits[_user] -= gmdAmount;
        totalBorrows -= _amount * decimalAdj;
        totalxBorrows -= _amount * decimalAdj * 1e18/usdPerxB;
        totalGmdDeposits -= gmdAmount;
        USDC.safeTransferFrom(msg.sender, address(this), _amount);
        gmdUSDC.safeTransfer(msg.sender, gmdAmount);
        require(userLTV(_user) > redLTV * 1e18/MAX_BPS, "GHALend: too much redemption");
        updateAPR();
        emit Redeem(_user, msg.sender, _amount);
    }

    function updateMaxRate(uint256 _maxRate) external onlyOwner {
        maxRate = _maxRate;
    }
    function setCaps(uint256 _depositCap, uint256 _gmdDepositCap, uint256 _borrowCap) external onlyOwner {
        depositCap = _depositCap;
        gmdDepositCap = _gmdDepositCap;
        borrowCap = _borrowCap;
    }

    function updateLTVs(uint256 _LTV, uint256 _redLTV) external onlyOwner {
        require(_LTV <= MAX_BPS, "out of range");
        require(redLTV <= MAX_BPS, "out of range");
        require(redLTV > _LTV, "too low");
        LTV = _LTV;
        redLTV = _redLTV;
    }

    function updateInterestRateCurve(uint256 _base, uint256 _slope1, uint256 _kink, uint256 _slope2) external onlyOwner {
        base = _base;
        slope1 = _slope1;
        kink = _kink;
        slope2 = _slope2;
    }

    function changeFees(uint256 _feeRate, address _treasury) external onlyOwner {
        require(_feeRate <= MAX_BPS, "out of range");
        require(_treasury != address(0));
        feeRate = _feeRate;
        treasury = _treasury;
    }

    // in a rare GMD shortfall event, we may need to yoink back deposits
    function yoink(IERC20 _token, address _to, uint256 _amount) external onlyOwner {
        _token.safeTransfer(_to, _amount);
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
        esGHA.safeTransfer(msg.sender, reward * esRatio / MAX_BPS);
        GHA.safeTransfer(msg.sender, reward * (MAX_BPS - esRatio) / MAX_BPS);
        emit GetReward(msg.sender, reward);
    }

    function setRewards(uint256 _rewardRate, uint256 _finishAt, uint256 _esRatio) external onlyOwner updateReward(address(0)) {
        require(_esRatio <= MAX_BPS, "out of range");
        esRatio = _esRatio;
        rewardRate = _rewardRate;
        finishAt = _finishAt;
        uint256 duration = finishAt - block.timestamp;
        require(
            rewardRate * duration * esRatio / MAX_BPS <= esGHA.balanceOf(address(this)),
            "es reward amount > balance"
        );
        require(
            rewardRate * duration * (MAX_BPS - esRatio) / MAX_BPS <= GHA.balanceOf(address(this)),
            "reward amount > balance"
        );
        updatedAt = block.timestamp;
    }

    function _min(uint x, uint y) private pure returns (uint) {
        return x <= y ? x : y;
    }

    // ui helper
    function depositAPR() external view returns (uint256) {
        return borrowAPR() * totalBorrows / totalDeposits * (MAX_BPS - feeRate) / MAX_BPS;
    }
}
