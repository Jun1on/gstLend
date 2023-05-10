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

contract GSTLend is Ownable, ReentrancyGuard {
    IGMDVault public GMDVault = IGMDVault(0x8080B5cE6dfb49a6B86370d6982B3e2A86FBBb08);
    uint256 public poolId;
    IERC20 public gmdUSDC;
    IERC20 public USDC;
    uint256 private decimalDiff;

    uint256 public totalDeposits    = 1;
    uint256 public totalxDeposits   = 1;
    uint256 public totalBorrows     = 1;
    uint256 public totalxBorrows    = 1;
    uint256 public totalGmdDeposits = 1;

    mapping(address => uint256) public xdeposits;
    mapping(address => uint256) public xborrows;
    mapping(address => uint256) public gmdDeposits;

    // security caps
    uint256 public gmdDepositCap = 500000 * 1e18;
    uint256 public maxRate = 11 * 1e17;

    uint256 LTV = 8000;
    uint256 public base   = 1e16 * 2;    // 2%
    uint256 public slope1 = 1e16 * 1/10; // 0.1%
    uint256 public kink   = 1e16 * 80;   // 80%
    uint256 public slope2 = 1e16 * 1;    // 1%

    uint256 public earnRateSec;
    uint256 public lastUpdate;

    uint256 fees = 2500;
    address public treasury = 0x03851F30cC29d86EE87a492f037B16642838a357;

    // Ratio to be paid out in esGST
    uint256 esRatio = 8000;

    IERC20 public GST = IERC20(0x0000000000000000000000000000000000000000);
    IERC20 public esGST = IERC20(0x0000000000000000000000000000000000000000);

    // Duration of rewards to be paid out (in seconds)
    uint public duration;
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
    function initialize(uint256 _poolId) external onlyOwner {
        poolId = _poolId;
        gmdUSDC = GMDVault.poolInfo(poolId).GDlptoken;
        USDC = GMDVault.poolInfo(poolId).lpToken;
        decimalDiff = 18 - USDC.decimals(); // decimal handling
    }

    function deposit(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        USDC.transferFrom(msg.sender, address(this), _amount);
        uint256 xamount = _amount * (10**decimalDiff) * 1e18/usdPerDepositedUSDC();
        xdeposits[msg.sender] += xamount;
        totalDeposits += _amount * (10**decimalDiff);
        totalxDeposits += xamount;
        update();
    }

    function withdraw(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(xdeposits[msg.sender] >= _amount * (10**decimalDiff) * 1e18/usdPerDepositedUSDC(), "GSTLend: Insufficient balance");
        uint256 xamount = _amount * (10**decimalDiff) * 1e18/usdPerDepositedUSDC();
        xdeposits[msg.sender] -= xamount;
        totalDeposits -= _amount * (10**decimalDiff);
        totalxDeposits -= xamount;
        USDC.transfer(msg.sender, _amount);
        update();
    }

    function depositGmd(uint256 _amount) external nonReentrant {
        gmdUSDC.transferFrom(msg.sender, address(this), _amount);
        require(_amount + totalGmdDeposits < gmdDepositCap, "GSTLend: Deposit exceeds cap");
        gmdDeposits[msg.sender] += _amount;
        totalGmdDeposits += _amount;
    }
    function withdrawGmd(uint256 _amount) external nonReentrant {
        update();
        uint256 freeUSD = valueOfDeposits(msg.sender) - xborrows[msg.sender] * (usdPerBorrowedUSDC()/1e18) / LTV*(10**4);
        uint256 freeCollateral = freeUSD * 1e18/usdPerGmdUSDC();
        require(freeCollateral >= _amount, "GSTLend: Insufficient collateral");
        gmdDeposits[msg.sender] -= _amount;
        totalGmdDeposits -= _amount;
        gmdUSDC.transfer(msg.sender, _amount);
    }

    function borrow(uint256 _amount) external nonReentrant {
        update();
        uint256 totalBorrowable = valueOfDeposits(msg.sender)*LTV/(10**4);
        uint256 borrowable = totalBorrowable - xborrows[msg.sender]*(usdPerBorrowedUSDC()/1e18);
        require(_amount * (10**decimalDiff) <= borrowable, "GSTLend: Insufficient collateral");
        uint256 xamount = _amount * (10**decimalDiff) * 1e18/usdPerBorrowedUSDC();
        xborrows[msg.sender] += xamount;
        totalBorrows += _amount * (10**decimalDiff);
        totalxBorrows += xamount;
        USDC.transfer(msg.sender, _amount);
        update();
    }

    function repay(uint256 _amount) external nonReentrant {
        update();
        uint256 borrows = xborrows[msg.sender] * usdPerBorrowedUSDC()/1e18;
        uint256 xamount;
        if (_amount * (10**decimalDiff) > borrows) {
            // repay all
            xamount = xborrows[msg.sender];
            USDC.transferFrom(msg.sender, address(this), borrows / (10**decimalDiff));
            xborrows[msg.sender] -= xamount;
            totalBorrows -= borrows;
        } else {
            xamount = _amount * (10**decimalDiff) * 1e18/usdPerBorrowedUSDC();
            USDC.transferFrom(msg.sender, address(this), _amount);
            xborrows[msg.sender] -= xamount;
            totalBorrows -= _amount * (10**decimalDiff);
        }
        totalxBorrows -= xamount;
        update();
    }

    // returns how much one gmdUSDC is worth
    function usdPerGmdUSDC() internal view returns (uint256) {
        uint256 totalShares = gmdUSDC.totalSupply();
        uint256 calculatedRate = GMDVault.poolInfo(poolId).totalStaked * 1e18 / totalShares;
        return _min(calculatedRate, maxRate);
    }

    function usdPerDepositedUSDC() internal view returns (uint256) {
        return totalDeposits * 1e18 / totalxDeposits;
    }

    function usdPerBorrowedUSDC() internal view returns (uint256) {
        return totalBorrows * 1e18 / totalxBorrows;
    }

    function borrowAPR() public view returns (uint256) {
        uint256 utilizationRatio = totalBorrows*1e18/totalDeposits;
        uint256 APR;

        if (utilizationRatio < kink) {
            APR = (slope1 * utilizationRatio*100) / 1e18 + base;
        } else {
            uint256 excessUtilization = utilizationRatio - kink;
            APR = (slope1 * kink*100) / 1e18 + (slope2 * excessUtilization*100) / 1e18 + base;
        }

        uint256 vaultAPR = GMDVault.poolInfo(poolId).APR*1e14;
        if (APR > vaultAPR) {
            return vaultAPR;
        }

        return APR;
    }

    // adds accrued interest and updates APR
    function update() internal {
        uint256 timepass = block.timestamp - lastUpdate;
        lastUpdate = block.timestamp;
        uint256 reward = earnRateSec*timepass;
        xdeposits[treasury] += reward * fees/(10**4) * 1e18/usdPerDepositedUSDC();
        totalDeposits += reward;
        totalBorrows += reward;
        earnRateSec = totalBorrows*borrowAPR()/1e18/(365 days);
    }

    // returns value of a user's collateral in usd
    function valueOfDeposits(address _user) internal view returns (uint256) {
        return (gmdDeposits[_user]*usdPerGmdUSDC())/1e18;
    }

    function updateMaxRate(uint256 _maxRate) external onlyOwner {
        maxRate = _maxRate;
    }
    function setGmdDepositCap(uint256 _gmdDepositCap) external onlyOwner {
        gmdDepositCap = _gmdDepositCap;
    }

    function updateInterestRateCurve(uint256 _base, uint256 _slope1, uint256 _kink, uint256 _slope2) external onlyOwner {
        base = _base;
        slope1 = _slope1;
        kink = _kink;
        slope2 = _slope2;
    }

    function changeFees(uint256 _fees, address _treasury) external onlyOwner {
        require(_fees <= 10**4, "out of range");
        fees = _fees;
        treasury = _treasury;
    }

    function changeEsRatio(uint256 _esRatio) external onlyOwner {
        require(_esRatio <= 10**4, "out of range");
        esRatio = _esRatio;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOwner {
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
        GST.transfer(msg.sender, reward * esRatio / 10**4);
        esGST.transfer(msg.sender, reward * (10**4 - esRatio) / 10**4);
    }

    function setRewardsDuration(uint _duration) external onlyOwner {
        require(finishAt < block.timestamp, "reward duration not finished");
        duration = _duration;
    }

    function notifyRewardAmount(
        uint _amount
    ) external onlyOwner updateReward(address(0)) {
        if (block.timestamp >= finishAt) {
            rewardRate = _amount / duration;
        } else {
            uint remainingRewards = (finishAt - block.timestamp) * rewardRate;
            rewardRate = (_amount + remainingRewards) / duration;
        }

        require(rewardRate > 0, "reward rate = 0");
        require(
            rewardRate * duration * esRatio / 10**4 <= esGST.balanceOf(address(this)),
            "escrowed reward amount > balance"
        );
        require(
            rewardRate * duration * (10**4 - esRatio) / 10**4 <= GST.balanceOf(address(this)),
            "reward amount > balance"
        );

        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;
    }

    function _min(uint x, uint y) private pure returns (uint) {
        return x <= y ? x : y;
    }
}
