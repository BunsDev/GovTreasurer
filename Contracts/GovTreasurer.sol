// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// GovTreasurer is the treasurer of GDAO. She may allocate GDAO and she is a fair lady <3

// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once GDAO is sufficiently
// distributed and the community can show to govern itself.

contract GovTreasurer is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // INFO | USER VARIABLES
    struct UserInfo {
        uint256 amount;     // How many tokens the user has provided.
        uint256 taxedAmount; // How many tokens the user is taxed (2% tax).
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // The pending GDAO entitled to a user is referred to as the pending reward:
        //
        //   pending reward = (user.amount * pool.accGDAOPerShare) - user.rewardDebt - user.taxedAmount
        //
        // Upon deposit and withdraw, the following occur:
        //   1. The pool's `accGDAOPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated and taxed as 'taxedAmount'.
        //   4. User's `rewardDebt` gets updated.
    }

    // INFO | POOL VARIABLES
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. GDAOs to distribute per block.
        uint256 taxRate;          // Rate at which the LP token is taxed.
        uint256 lastRewardBlock;  // Last block number that GDAOs distribution occurs.
        uint256 accGDAOPerShare; // Accumulated GDAOs per share, times 1e12. See below.
    }

    address public devaddr;
    IERC20 public rewardToken;
    uint256 public bonusEndBlock;
    uint256 public GDAOPerBlock;
    uint256 public constant BONUS_MULTIPLIER = 1;

    PoolInfo[] public poolInfo;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 12;
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        address _rewardToken,
        address _devaddr,
        uint256 _GDAOPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    )   public {
        rewardToken = IERC20(_rewardToken); // GDAO Reward
        devaddr = _devaddr; // Multisig Treasury Account
        GDAOPerBlock = _GDAOPerBlock; // Rewards Rate per Block
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }


    // VALIDATION | ELIMINATES POOL DUPLICATION RISK
    function checkPoolDuplicate(IERC20 _lpToken) public view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].lpToken != _lpToken, "add: existing pool?");
        }
    }

    // ADD | NEW TOKEN POOL
    function add(uint256 _allocPoint, IERC20 _lpToken, uint256 _taxRate, bool _withUpdate) public 
        onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            taxRate: _taxRate,
            lastRewardBlock: lastRewardBlock,
            accGDAOPerShare: 0
        }));
    }

    // UPDATE | ALLOCATION POINT
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // RETURN | REWARD MULTIPLIER OVER GIVEN BLOCK RANGE | INCLUDES START BLOCK
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        _from = _from >= startBlock ? _from : startBlock;
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    // VIEW | PENDING REWARD
    function pendingGDAO(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGDAOPerShare = pool.accGDAOPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 GDAOReward = multiplier.mul(GDAOPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accGDAOPerShare = accGDAOPerShare.add(GDAOReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accGDAOPerShare).div(1e12).sub(user.rewardDebt);
    }

    // UPDATE | (ALL) REWARD VARIABLES | BEWARE: HIGH GAS POTENTIAL
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // UPDATE | (ONE POOL) REWARD VARIABLES
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 GDAOReward = multiplier.mul(GDAOPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        safeGDAOTransfer(address(this), GDAOReward);
        pool.accGDAOPerShare = pool.accGDAOPerShare.add(GDAOReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // VALIDATE | AUTHENTICATE _PID
    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "gov: pool exists?");
        _;
    }

    // WITHDRAW | FARMING ASSETS (TOKENS) WITH NO REWARDS | EMERGENCY ONLY | RE-ENTRANCY DEFENSE
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        user.amount = 0;
        user.taxedAmount = 0;
        user.rewardDebt = 0;
        
        pool.lpToken.safeTransfer(address(msg.sender), user.amount.sub(user.taxedAmount));

        emit EmergencyWithdraw(msg.sender, _pid, user.amount.sub(user.taxedAmount));        
    }

    // DEPOSIT | FARMING ASSETS (TOKENS) | RE-ENTRANCY DEFENSE
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accGDAOPerShare).div(1e12).sub(user.rewardDebt);
        
        user.amount = user.amount.add(_amount);
        user.taxedAmount = user.amount.div(pool.taxRate); // pool.taxRate x amount = 'taxedAmount'
        user.rewardDebt = user.amount.mul(pool.accGDAOPerShare).div(1e12);

        safeGDAOTransfer(msg.sender, pending);
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount.sub(user.taxedAmount));
        pool.lpToken.safeTransferFrom(address(msg.sender), address(devaddr), _amount.div(pool.taxRate));

        emit Deposit(msg.sender, _pid, _amount);
    }

    // WITHDRAW | FARMING ASSETS (TOKENS) | RE-ENTRANCY DEFENSE
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accGDAOPerShare).div(1e12).sub(user.taxedAmount).sub(user.rewardDebt);

        user.amount = user.amount.sub(_amount);
        user.taxedAmount = user.amount.div(pool.taxRate); // pool.taxRate x amount = 'taxedAmount'
        user.rewardDebt = user.amount.mul(pool.accGDAOPerShare).div(1e12);

        safeGDAOTransfer(msg.sender, pending);
        pool.lpToken.safeTransfer(address(msg.sender), _amount.sub(user.taxedAmount));

        emit Withdraw(msg.sender, _pid, _amount.sub(user.taxedAmount));
    }

    // SAFE TRANSFER FUNCTION | ACCOUNTS FOR ROUNDING ERRORS | ENSURES SUFFICIENT GDAO IN POOLS.
    function safeGDAOTransfer(address _to, uint256 _amount) internal {
        uint256 GDAOBal = rewardToken.balanceOf(address(this));
        if (_amount > GDAOBal) {
            rewardToken.transfer(_to, GDAOBal);
        } else {
            rewardToken.transfer(_to, _amount);
        }
    }

    // UPDATE | DEV ADDRESS | DEV-ONLY
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
