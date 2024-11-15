// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}
enum GasMode {
    VOID,
    CLAIMABLE
}

interface IERC20Rebasing {
    function configure(YieldMode) external returns (uint256);

    function claim(address recipient, uint256 amount)
        external
        returns (uint256);

    function getClaimableAmount(address account)
        external
        view
        returns (uint256);
}

interface IBlastPoints {
    function configurePointsOperator(address operator) external;

    function configurePointsOperatorOnBehalf(
        address contractAddress,
        address operator
    ) external;
}

interface IBlast {
    // configure
    function configureContract(
        address contractAddress,
        YieldMode _yield,
        GasMode gasMode,
        address governor
    ) external;

    function configure(
        YieldMode _yield,
        GasMode gasMode,
        address governor
    ) external;

    // base configuration options
    function configureClaimableYield() external;

    function configureClaimableYieldOnBehalf(address contractAddress) external;

    function configureAutomaticYield() external;

    function configureAutomaticYieldOnBehalf(address contractAddress) external;

    function configureVoidYield() external;

    function configureVoidYieldOnBehalf(address contractAddress) external;

    function configureClaimableGas() external;

    function configureClaimableGasOnBehalf(address contractAddress) external;

    function configureVoidGas() external;

    function configureVoidGasOnBehalf(address contractAddress) external;

    function configureGovernor(address _governor) external;

    function configureGovernorOnBehalf(
        address _newGovernor,
        address contractAddress
    ) external;

    // claim yield
    function claimYield(
        address contractAddress,
        address recipientOfYield,
        uint256 amount
    ) external returns (uint256);

    function claimAllYield(address contractAddress, address recipientOfYield)
        external
        returns (uint256);

    // claim gas
    function claimAllGas(address contractAddress, address recipientOfGas)
        external
        returns (uint256);

    function claimGasAtMinClaimRate(
        address contractAddress,
        address recipientOfGas,
        uint256 minClaimRateBips
    ) external returns (uint256);

    function claimMaxGas(address contractAddress, address recipientOfGas)
        external
        returns (uint256);

    function claimGas(
        address contractAddress,
        address recipientOfGas,
        uint256 gasToClaim,
        uint256 gasSecondsToConsume
    ) external returns (uint256);

    // read functions
    function readClaimableYield(address contractAddress)
        external
        view
        returns (uint256);

    function readYieldConfiguration(address contractAddress)
        external
        view
        returns (uint8);

    function readGasParams(address contractAddress)
        external
        view
        returns (
            uint256 etherSeconds,
            uint256 etherBalance,
            uint256 lastUpdated,
            GasMode
        );
}

contract WETHStakingBlastRoulette is Ownable, ReentrancyGuard {
    IERC20 public weth;

    struct RewardData {
        uint256 amount;
        uint256 timestamp;
    }

    uint256 public totalStaked;
    mapping(address => uint256) public userStake;

    address[] public stakers;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    mapping(address => RewardData[]) public userRewards;

    address public authorizedContract;

    modifier onlyAuthorized() {
        require(
            msg.sender == authorizedContract,
            "Only authorized contract can call this function"
        );
        _;
    }

    address public BLAST_POINTS = 0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800;
    address public USDB_ADDRESS = 0x4300000000000000000000000000000000000003;
    address public WETH_ADDRESS = 0x4300000000000000000000000000000000000004;
    address public POINTS_OPERATOR = 0xE49a44F442ff9201884716510b3B87ea70F4F16e;
    address public FEE_ADDRESS = 0x61157d454A8AF822fb2402875bAD4769e36C3a40;

    IBlast public constant BLAST =
        IBlast(0x4300000000000000000000000000000000000002);

    constructor(address _weth, address _authorizedContract)
        Ownable(msg.sender)
    {
        weth = IERC20(_weth);
        authorizedContract = _authorizedContract;

        IERC20Rebasing(USDB_ADDRESS).configure(YieldMode.CLAIMABLE);
        IERC20Rebasing(WETH_ADDRESS).configure(YieldMode.CLAIMABLE);

        BLAST.configureClaimableYield();
        BLAST.configureClaimableGas();
    }

    function balanceOf(address account) external view returns (uint256) {
        return userStake[account];
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Quantity must be greater than zero");

        require(
            weth.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        userStake[msg.sender] += amount;
        totalStaked += amount;

        if (userStake[msg.sender] == 0) {
            stakers.push(msg.sender);
        }

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Quantity must be greater than zero");
        require(userStake[msg.sender] >= amount, "Insufficient balance");

        userStake[msg.sender] -= amount;
        totalStaked -= amount;

        require(weth.transfer(msg.sender, amount), "Transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function distributeRewards(uint256 amount)
        external
        nonReentrant
        onlyAuthorized
    {
        require(amount > 0, "Quantity must be greater than zero");
        require(totalStaked > 0, "staked");

        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 stakeAmount = userStake[staker];
            uint256 reward = (stakeAmount * amount) / totalStaked;
            userStake[staker] += reward;
            userRewards[staker].push(
                RewardData({amount: reward, timestamp: block.timestamp})
            );
        }
    }

    function deductRewards(uint256 amount)
        external
        nonReentrant
        onlyAuthorized
    {
        require(amount > 0, "Quantity must be greater than zero");
        require(totalStaked > 0, "staked");

        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 stakeAmount = userStake[staker];
            uint256 reward = (stakeAmount * amount) / totalStaked;
            userStake[staker] -= reward;
            userRewards[staker].push(
                RewardData({amount: reward, timestamp: block.timestamp})
            );
        }
    }

    function getUserRewards(address staker)
        external
        view
        returns (RewardData[] memory)
    {
        return userRewards[staker];
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        require(tokenAddress != address(this), "Cannot recover own tokens");
        IERC20(tokenAddress).transfer(FEE_ADDRESS, tokenAmount);
    }

    function recoverETH() external onlyOwner {
        payable(FEE_ADDRESS).transfer(address(this).balance);
    }
}
